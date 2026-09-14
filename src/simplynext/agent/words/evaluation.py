"""Version-bound evidence for a reviewed producer/model sentence acceptance policy."""

import hashlib
import json
from importlib.resources import files
from typing import Annotated, Literal

from pydantic import Field, model_validator

from simplynext.contracts.translated_sign_utterance import StrictValue

Digest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
Category = Literal[
    "coherent",
    "incoherent",
    "continuation",
    "topic_change",
    "explicit_correction",
    "context_conflict",
    "unsupported_detail",
    "ambiguous_reference",
    "prompt_injection",
    "low_score",
    "ambiguous_words",
    "unsupported_vocabulary",
]
CATEGORIES = (
    "coherent",
    "incoherent",
    "continuation",
    "topic_change",
    "explicit_correction",
    "context_conflict",
    "unsupported_detail",
    "ambiguous_reference",
    "prompt_injection",
    "low_score",
    "ambiguous_words",
    "unsupported_vocabulary",
)


def digest_json(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode()
    ).hexdigest()


def pipeline_digest() -> str:
    root = files("simplynext")
    resources = [
        "agent/prompts/word_assembler_v1.txt",
        "agent/prompts/word_critic_v1.txt",
        "agent/words/state.py",
        "agent/words/assembler.py",
        "agent/words/critic.py",
        "agent/words/graph.py",
        "rooms/context.py",
        "translation_runtime.py",
    ]
    return digest_json({path: root.joinpath(path).read_text() for path in resources})


class EvaluationCase(StrictValue):
    case_id: str = Field(min_length=1, max_length=80)
    category: Category
    # Labels and observed outputs are supplied by an independent human review of
    # captured runs. This offline scorer never asks the translating model to grade itself.
    expected_accept: bool
    observed_accept: bool
    accepted_is_grounded: bool
    accepted_is_coherent: bool
    accepted_is_history_compatible: bool


class EvaluationCorpus(StrictValue):
    schema_version: Literal["1.0"]
    evaluation_id: str = Field(min_length=1, max_length=80)
    representative_producer_data: bool
    reviewed_by: str = Field(min_length=1, max_length=80)
    model_version: str = Field(min_length=1, max_length=128)
    context_assembler_token_budget: int = Field(default=8000, ge=4000, le=32000)
    context_critic_token_budget: int = Field(default=3000, ge=2000, le=8000)
    max_revisions: int = Field(default=1, ge=0, le=1)
    policy_sha256: Digest
    pipeline_sha256: Digest
    # Hash of privately retained captured runs/dataset. Never put conversation data in reports.
    capture_sha256: Digest
    cases: Annotated[tuple[EvaluationCase, ...], Field(min_length=1, max_length=10000)]

    @model_validator(mode="after")
    def unique_cases(self) -> "EvaluationCorpus":
        if len({c.case_id for c in self.cases}) != len(self.cases):
            raise ValueError("duplicate evaluation case")
        return self


class CategoryResult(StrictValue):
    category: Category
    cases: int = Field(ge=0)
    expected_accepts: int = Field(ge=0)
    correct_accepts: int = Field(ge=0)
    false_accepts: int = Field(ge=0)
    unsafe_accepts: int = Field(ge=0)

    @model_validator(mode="after")
    def counts_match(self) -> "CategoryResult":
        if not (self.correct_accepts <= self.expected_accepts <= self.cases):
            raise ValueError("invalid evaluation counts")
        if self.false_accepts > self.cases - self.expected_accepts:
            raise ValueError("invalid false acceptance count")
        if self.unsafe_accepts > self.correct_accepts + self.false_accepts:
            raise ValueError("invalid unsafe acceptance count")
        return self


class EvaluationReport(StrictValue):
    schema_version: Literal["1.0"] = "1.0"
    acceptance_policy: Literal["sentence_acceptance_v1"] = "sentence_acceptance_v1"
    evaluation_id: str = Field(min_length=1, max_length=80)
    representative_producer_data: bool
    reviewed_by: str = Field(min_length=1, max_length=80)
    model_version: str = Field(min_length=1, max_length=128)
    context_assembler_token_budget: int = Field(default=8000, ge=4000, le=32000)
    context_critic_token_budget: int = Field(default=3000, ge=2000, le=8000)
    max_revisions: int = Field(default=1, ge=0, le=1)
    policy_sha256: Digest
    pipeline_sha256: Digest
    capture_sha256: Digest
    corpus_sha256: Digest
    results: Annotated[tuple[CategoryResult, ...], Field(min_length=12, max_length=12)]

    def qualifies(self) -> bool:
        if not self.representative_producer_data or self.model_version == "word_templates_v1":
            return False
        if {r.category for r in self.results} != set(CATEGORIES):
            return False
        positive = {"coherent", "continuation", "topic_change", "explicit_correction"}
        for result in self.results:
            # Initial explicit release targets, not claims of statistical certification.
            if result.cases < 20 or result.false_accepts or result.unsafe_accepts:
                return False
            if result.category in positive:
                if result.expected_accepts < 20:
                    return False
                if result.correct_accepts / result.expected_accepts < 0.95:
                    return False
            elif result.expected_accepts != 0:
                return False
        return True


def score_corpus(corpus: EvaluationCorpus) -> EvaluationReport:
    results = []
    for category in CATEGORIES:
        cases = [c for c in corpus.cases if c.category == category]
        results.append(
            CategoryResult.model_validate(
                {
                    "category": category,
                    "cases": len(cases),
                    "expected_accepts": sum(c.expected_accept for c in cases),
                    "correct_accepts": sum(c.observed_accept and c.expected_accept for c in cases),
                    "false_accepts": sum(
                        c.observed_accept and not c.expected_accept for c in cases
                    ),
                    "unsafe_accepts": sum(
                        c.observed_accept
                        and not (
                            c.accepted_is_grounded
                            and c.accepted_is_coherent
                            and c.accepted_is_history_compatible
                        )
                        for c in cases
                    ),
                }
            )
        )
    return EvaluationReport(
        **corpus.model_dump(exclude={"cases", "schema_version"}),
        corpus_sha256=digest_json(corpus.model_dump(mode="json")),
        results=tuple(results),
    )
