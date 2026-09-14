import json
from pathlib import Path
from uuid import uuid4

import pytest
from pydantic import ValidationError
from test_word_agents import ENTRIES, FakeConverse, engine, policy, response, utterance, verdict

from simplynext.agent.words.evaluation import (
    CATEGORIES,
    EvaluationCorpus,
    EvaluationReport,
    digest_json,
    pipeline_digest,
    score_corpus,
)
from simplynext.agent.words.state import WordVerdict
from simplynext.config import Settings
from simplynext.contracts.translated_sign_utterance import parse_value
from simplynext.rooms.context import ConversationContext, ConversationTurn
from simplynext.translation_runtime import load_word_policy


def history(text="Where is the table?"):
    return ConversationContext(
        room_id=uuid4(),
        context_version=1,
        recent_turns=(
            ConversationTurn(server_sequence=1, speaker="hearing", source="text", text=text),
        ),
    )


@pytest.mark.parametrize(
    "relation",
    [
        "continuation",
        "topic_change",
        "explicit_correction",
        "no_relevant_history",
    ],
)
async def test_compatible_coherent_grounded_sentence_is_released(relation):
    decision = verdict()
    decision["history_relation"] = relation
    decision["reference_sequences"] = [1] if relation == "continuation" else []
    client = FakeConverse(response(ENTRIES[0]["draft"]), response(decision))
    result = await engine(client).process(utterance(), history())
    assert result.status == "accepted" and result.text == "I want water."
    assert len(client.calls) == 2


@pytest.mark.parametrize(
    "relation,coherent,reason",
    [
        ("contradiction", True, "context_conflict"),
        ("uncertain", True, "context_conflict"),
        ("no_relevant_history", False, "unnatural_sentence"),
    ],
)
async def test_each_acceptance_test_fails_closed(relation, coherent, reason):
    decision = verdict(False)
    decision.update(
        history_relation=relation,
        standalone_coherent=coherent,
        reference_sequences=[1] if relation == "contradiction" else [],
        revision_instruction="abstain",
        reason_code=reason,
    )
    client = FakeConverse(response(ENTRIES[0]["draft"]), response(decision))
    result = await engine(client).process(utterance(), history())
    assert result.status == "repair" and result.reason_code == reason
    assert "text" not in result.model_dump() and len(client.calls) == 2


@pytest.mark.parametrize(
    "change",
    [
        {"standalone_coherent": False},
        {"history_relation": "uncertain"},
        {"history_relation": "contradiction", "reference_sequences": [1]},
    ],
)
def test_supported_boolean_cannot_override_quality_failure(change):
    with pytest.raises(ValidationError):
        parse_value(WordVerdict, json.dumps(dict(verdict(), **change)))


async def test_critic_cannot_invent_history_reference():
    decision = dict(verdict(), history_relation="continuation", reference_sequences=[999])
    client = FakeConverse(response(ENTRIES[0]["draft"]), response(decision))
    result = await engine(client).process(utterance(), history())
    assert result.status == "repair" and result.reason_code == "invalid_output"


async def test_missing_new_quality_fields_is_not_an_implicit_pass():
    decision = verdict()
    del decision["standalone_coherent"]
    client = FakeConverse(response(ENTRIES[0]["draft"]), response(decision))
    assert (await engine(client).process(utterance(), history())).status == "repair"


async def test_new_topic_still_cannot_smuggle_unsupported_current_words():
    draft = json.loads(json.dumps(ENTRIES[0]["draft"]))
    draft["alignment"][0]["text"] = "Alice"
    draft["candidate_text"] = draft["tts_text"] = "Alice want water."
    client = FakeConverse(
        response(draft), response(dict(verdict(), history_relation="topic_change"))
    )
    assert (await engine(client).process(utterance(), history())).status == "repair"
    assert len(client.calls) == 1


def corpus(profile=None):
    profile = profile or policy().model_copy(update={"purpose": "producer_evaluated"})
    positives = {"coherent", "continuation", "topic_change", "explicit_correction"}
    return parse_value(
        EvaluationCorpus,
        json.dumps(
            {
                "schema_version": "1.0",
                "evaluation_id": profile.evaluation_id,
                "representative_producer_data": True,
                "reviewed_by": "UNIT_TEST_ONLY",
                "model_version": "claude-haiku-4-5-20251001",
                "policy_sha256": digest_json(profile.model_dump(mode="json")),
                "pipeline_sha256": pipeline_digest(),
                "capture_sha256": "0" * 64,
                "cases": [
                    {
                        "case_id": f"{category}-{i}",
                        "category": category,
                        "expected_accept": category in positives,
                        "observed_accept": category in positives,
                        "accepted_is_grounded": True,
                        "accepted_is_coherent": True,
                        "accepted_is_history_compatible": True,
                    }
                    for category in CATEGORIES
                    for i in range(20)
                ],
            }
        ),
        max_bytes=5_000_000,
    )


def test_evaluation_scores_both_safety_and_false_topic_rejections():
    data = corpus().model_dump(mode="json")
    report = score_corpus(parse_value(EvaluationCorpus, json.dumps(data), max_bytes=5_000_000))
    assert report.qualifies()
    assert all(r.cases == 20 for r in report.results)
    # A reject-everything critic cannot qualify; neither can a fluent hallucination.
    for case in data["cases"]:
        if case["category"] == "topic_change":
            case["observed_accept"] = False
    assert not score_corpus(
        parse_value(EvaluationCorpus, json.dumps(data), max_bytes=5_000_000)
    ).qualifies()
    data = corpus().model_dump(mode="json")
    data["cases"][0]["accepted_is_grounded"] = False
    assert not score_corpus(
        parse_value(EvaluationCorpus, json.dumps(data), max_bytes=5_000_000)
    ).qualifies()
    data = corpus().model_dump(mode="json")
    data["cases"][-1]["observed_accept"] = True
    assert not score_corpus(
        parse_value(EvaluationCorpus, json.dumps(data), max_bytes=5_000_000)
    ).qualifies()


@pytest.mark.parametrize(
    "mutation", ["synthetic", "missing", "model", "pipeline", "policy", "coverage"]
)
def test_production_requires_exact_qualified_evidence(tmp_path, mutation):
    profile = policy().model_copy(update={"purpose": "producer_evaluated"})
    report = score_corpus(corpus(profile)).model_dump(mode="json")
    if mutation == "synthetic":
        profile = policy()
    if mutation in {"model", "pipeline", "policy"}:
        report[
            {"model": "model_version", "pipeline": "pipeline_sha256", "policy": "policy_sha256"}[
                mutation
            ]
        ] = "wrong-model" if mutation == "model" else "f" * 64
    if mutation == "coverage":
        report["results"][0].update(cases=1, expected_accepts=1, correct_accepts=1)
    policy_path, report_path = tmp_path / "policy.json", tmp_path / "report.json"
    policy_path.write_text(profile.model_dump_json())
    report_path.write_text(json.dumps(report))
    settings = Settings(
        _env_file=None,
        environment="production",
        anthropic_enabled=True,
        anthropic_lease_owner="test",
        anthropic_input_usd_per_million_tokens=1,
        anthropic_output_usd_per_million_tokens=5,
        anthropic_cache_write_usd_per_million_tokens=1,
        anthropic_cache_read_usd_per_million_tokens=1,
        word_policy_path=policy_path,
        word_evaluation_path=None if mutation == "missing" else report_path,
    )
    with pytest.raises(ValueError):
        load_word_policy(settings)


def test_matching_test_evidence_qualifies_without_calling_provider(tmp_path):
    profile = policy().model_copy(update={"purpose": "producer_evaluated"})
    report = score_corpus(corpus(profile))
    policy_path, report_path = tmp_path / "policy.json", tmp_path / "report.json"
    policy_path.write_text(profile.model_dump_json())
    report_path.write_text(report.model_dump_json())
    settings = Settings(
        _env_file=None,
        environment="production",
        anthropic_enabled=True,
        anthropic_lease_owner="test",
        anthropic_input_usd_per_million_tokens=1,
        anthropic_output_usd_per_million_tokens=5,
        anthropic_cache_write_usd_per_million_tokens=1,
        anthropic_cache_read_usd_per_million_tokens=1,
        word_policy_path=policy_path,
        word_evaluation_path=report_path,
    )
    assert load_word_policy(settings) == profile
    assert parse_value(EvaluationReport, report_path.read_bytes()).qualifies()


def test_offline_scorer_has_no_conversation_payload_in_report(tmp_path):
    import subprocess
    import sys

    source, output = tmp_path / "corpus.json", tmp_path / "report.json"
    source.write_text(corpus().model_dump_json())
    script = Path(__file__).parents[1] / "scripts/evaluate_word_policy.py"
    run = subprocess.run(
        [sys.executable, str(script), str(source), "--output", str(output)],
        capture_output=True,
        text=True,
        check=True,
    )
    assert run.stdout.strip() == "qualification=passed"
    report = json.loads(output.read_text())
    assert "cases" not in report and "capture_sha256" in report
