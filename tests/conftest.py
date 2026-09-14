"""Never let a developer's local provider settings spend credits during collection."""

import os

# main.app is built at import time, before fixtures can monkeypatch Settings.
# Provider unit tests opt in explicitly and inject their fake SDKs.
os.environ["SIMPLYNEXT_BEDROCK_ENABLED"] = "false"
os.environ["SIMPLYNEXT_ANTHROPIC_ENABLED"] = "false"
