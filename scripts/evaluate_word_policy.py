"""Score privately reviewed producer captures; emits only aggregate release evidence."""

import argparse
from pathlib import Path

from simplynext.agent.words.evaluation import EvaluationCorpus, score_corpus
from simplynext.contracts.translated_sign_utterance import parse_value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        corpus = parse_value(EvaluationCorpus, args.corpus.read_bytes(), max_bytes=5_000_000)
        report = score_corpus(corpus)
    except (OSError, ValueError):
        parser.exit(2, "Invalid evaluation corpus; no report generated.\n")
    args.output.write_text(report.model_dump_json(indent=2) + "\n")
    print("qualification=" + ("passed" if report.qualifies() else "failed"))
    return 0 if report.qualifies() else 1


if __name__ == "__main__":
    raise SystemExit(main())
