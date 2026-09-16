# Sentence acceptance and producer qualification v1

## Two sentence tests

1. **Standalone coherence:** the sentence is complete, natural English and makes sense by itself.
   Aligned words alone are insufficient: “Table table.” still fails.
2. **Compatibility with conversation:** the assembly does not introduce an unsupported contradiction
   or depend on an unresolved reference. The current words remain the primary evidence.

A history test must not measure topic similarity. The independent critic labels the relation:

| Relation | Decision if coherence and grounding pass |
| --- | --- |
| Continuation or answer | Accept |
| New topic, including an abrupt change | Accept; no transition phrase required |
| Explicit correction/change of mind grounded in current words | Accept |
| No relevant history | Accept |
| Contradiction introduced by assembly about the same referent, time and proposition | Repair |
| Essential reference remains ambiguous | Repair |

Example: after discussing a table, current words `WATER I WANT` may become “I want water.” It starts
another topic and passes. Do not invent “by the way” to justify it. A participant may disagree with
another participant or change their mind; history is not a truth constraint that overrides current
sign evidence. A lost/excerpted claim or summary alone cannot prove contradiction.

The critic returns `standalone_coherent`, `history_relation`, bounded `reference_sequences`,
`supported`, reason and optional enum revision instruction. It cannot rewrite the sentence.
A supported verdict with failed coherence or contradiction/uncertainty is structurally invalid.
Reference sequences must exist in the context actually supplied. One revision remains the maximum;
subsequent failure becomes a safe repeat/type repair with no speculative text.

## Existing evidence safeguards

The two tests judge sentence quality. The frozen contract additionally requires fidelity to the
signer: every meaningful output span must align to current words, no invented names/numbers/person/
negation/tense/question force, exact candidate/TTS identity and strict output bounds. Fluent,
contextually plausible hallucinations cannot pass merely because they satisfy the two quality tests.
Producer identity, vocabulary, nonzero score, evaluated score threshold and alternative margin are
checked before any model call. Normalized model scores are **not probabilities**. Thresholds must
come from this producer's held-out data; the synthetic 0.5/0.1 example is not production calibration.

## What “producer evaluated” means operationally

Configure a `WordPolicy` containing the exact frozen `WordProducer`, reviewed vocabulary,
`evaluation_id`, `purpose: producer_evaluated`, `min_score` and `min_margin`.
Production additionally requires `SIMPLYNEXT_WORD_EVALUATION_PATH`, a strict `EvaluationReport`:

- matching evaluation ID and SHA-256 of canonical policy JSON (binds producer, vocabulary and scores);
- matching model ID and pipeline hash (prompts, draft/verdict, grounding, graph, context and policy code);
- reviewer identity, representative-producer-data attestation, private capture hash and corpus hash;
- all 12 required categories with enough held-out observations and acceptable measured results.

Initial release targets: at least 20 independently reviewed cases in each category; no false or
unsafe acceptances in the reviewed set; at least 95% acceptance of eligible coherent, continuation,
topic-change and explicit-correction cases (at least 20 positives each). Negative categories cover
incoherence, unsupported context conflict/detail, ambiguous references, prompt injection, low scores,
ambiguous alternatives and unsupported vocabulary. These are explicit initial engineering targets,
not a statistical certification or a claim of zero real-world error. Review them against actual
producer error costs and expand signer/device/topic coverage before public release.

Use a held-out set of real producer outputs across signers, lighting, devices, confidence bins,
vocabulary/alternatives and 60/120/240-turn histories. Split by signer/session to reduce leakage.
Tune score/margin settings on a separate calibration partition. Human reviewers assess the actual
released output for grounding, standalone coherence and compatibility, including abrupt topics,
corrections, conflicting opinions and untrusted text. Preserve model failures/repairs in the results;
a critic that rejects every topic change must fail qualification.

## Evaluation artifacts and offline scorer

`agent/words/evaluation.py` defines `EvaluationCorpus`, `EvaluationCase` and `EvaluationReport`.
A corpus records the metadata above and private case IDs, category, `expected_accept`,
`observed_accept`, `accepted_is_grounded`, `accepted_is_coherent` and
`accepted_is_history_compatible`. These labels come from independent review of captured runs,
not the translating model's self-assessment. Store original captures privately with consent and
retention controls; aggregate reports contain no conversation text.

```bash
python scripts/evaluate_word_policy.py /private/reviewed-corpus.json \
  --output /private/reviewed-report.json
```

The command makes no provider calls and exits nonzero for failed qualification. Generate policy
hashes with `digest_json(policy.model_dump(mode="json"))` and the pipeline hash with
`pipeline_digest()` from `simplynext.agent.words.evaluation`. Capture them with the evaluated run,
not retroactively against changed code. Copy reviewed policy/report into a deployment-controlled
read-only location and set both paths. Never relabel synthetic test data as representative data.

This is an operator-controlled attestation mechanism; hashes bind versions/artifacts, not the truth
of human labels. The runtime cannot independently prove dataset provenance or reviewer competence.
Missing/mismatched/failed evidence refuses production policy startup before provider initialization.
No policy configured keeps typed chat available and signed utterances on safe no-spend repair.

## Current evidence and limits

Local synthetic cases/provider doubles verify dispatch, verdict parsing, acceptance gates, topic
labels, missing/invalid evidence, release targets and version binding. They do not establish whether
a real model correctly classifies a topic change or real signs. No representative dataset/report or
live model evaluation was supplied in this round, so no production-qualified profile is shipped.
Deterministic templates are a no-spend demo/degraded path: they attest reviewed grammar/grounding
only with empty history and repair when a contextual judgment is needed.
