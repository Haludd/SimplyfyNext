"""Read-only production configuration gate; no provider initialization or secret output."""

import argparse
import json
from datetime import date, timedelta

from simplynext.config import Settings
from simplynext.translation_runtime import load_word_policy


def check(settings: Settings, verified_on: date | None = None) -> dict[str, object]:
    if settings.environment != "production":
        raise ValueError("production environment required")
    if settings.host != "0.0.0.0":
        raise ValueError("production must bind 0.0.0.0")
    if not any(
        h not in {"localhost", "127.0.0.1", "testserver", "healthcheck.railway.app"}
        and not h.endswith((".invalid", ".localhost"))
        for h in settings.allowed_hosts
    ):
        raise ValueError("public hostname required")
    if settings.operator_docs_enabled:
        raise ValueError("disable operator docs for release verification")
    if (
        settings.operator_metrics_token is None
        or len(settings.operator_metrics_token.get_secret_value()) < 32
    ):
        raise ValueError("dedicated metrics secret must contain at least 32 characters")
    policy = load_word_policy(settings)
    enabled = settings.anthropic_enabled or settings.bedrock_enabled or settings.gemini_enabled
    if enabled:
        if policy is None:
            raise ValueError("qualify producer and model before enabling paid production mode")
        if (
            verified_on is None
            or not date.today() - timedelta(days=7) <= verified_on <= date.today()
        ):
            raise ValueError("verify selected model pricing within seven days of release")
        provider = (
            "gemini"
            if settings.gemini_enabled
            else "anthropic"
            if settings.anthropic_enabled
            else "bedrock"
        )
        for kind in ("input", "output", "cache_write", "cache_read"):
            field = f"{provider}_{kind}_usd_per_million_tokens"
            if field not in settings.model_fields_set or getattr(settings, field) <= 0:
                raise ValueError("all four positive provider prices must be explicit")
        path = settings.provider_spend_journal_path
        if path is None or not path.is_absolute() or not path.is_file():
            raise ValueError("mount the persistent aggregate-spend volume before provider startup")
    return {
        "configuration": "passed",
        "provider_enabled": enabled,
        "sentence_qualification": "configured" if policy is not None else "not_configured",
        "scope": "configuration only; hosting, volume persistence and physical devices unverified",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pricing-verified-on", type=date.fromisoformat)
    parser.add_argument(
        "--init-journal",
        action="store_true",
        help="Safely provision an initial usage.json if missing",
    )
    args = parser.parse_args()
    try:
        settings = Settings(_env_file=None)  # type: ignore[call-arg]
        if (
            args.init_journal
            and settings.provider_spend_journal_path is not None
            and not settings.provider_spend_journal_path.exists()
        ):
            from simplynext.spend_journal import init_spend_journal

            init_spend_journal(settings.provider_spend_journal_path)
        result = check(settings, args.pricing_verified_on)
    except Exception:
        # Validation exceptions can embed configuration values; never print them.
        print(json.dumps({"configuration": "failed", "reason": "review_production_configuration"}))
        raise SystemExit(1) from None
    print(json.dumps(result))


if __name__ == "__main__":
    main()
