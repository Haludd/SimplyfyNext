"""Replaceable words-only translation boundary; no model/landmark imports."""

from typing import Protocol

import httpx

from .contracts import TranslationResult, WordsInput


class Translator(Protocol):
    mode: str

    async def translate(
        self, payload: WordsInput, context: list[dict[str, str]]
    ) -> TranslationResult: ...


class DemoTranslator:
    """A literal word preview, explicitly not a sign-language sentence translator."""

    mode = "demo"

    async def translate(
        self, payload: WordsInput, context: list[dict[str, str]]
    ) -> TranslationResult:
        return TranslationResult(
            status="accepted", text=" ".join(item.word for item in payload.words)
        )


class HttpTranslator:
    mode = "http"

    def __init__(self, url: str, token: str | None = None) -> None:
        self.url = url
        self.token = token

    async def translate(
        self, payload: WordsInput, context: list[dict[str, str]]
    ) -> TranslationResult:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        async with (
            httpx.AsyncClient(timeout=12, follow_redirects=False) as client,
            client.stream(
                "POST",
                self.url,
                json={**payload.model_dump(mode="json"), "context": context},
                headers=headers,
            ) as response,
        ):
            response.raise_for_status()
            body = bytearray()
            async for chunk in response.aiter_bytes():
                body.extend(chunk)
                if len(body) > 16384:
                    raise ValueError("translation response too large")
        return TranslationResult.model_validate_json(body)
