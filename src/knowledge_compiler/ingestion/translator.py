"""Translation backends for multilingual content.

Supports multiple translation services with automatic fallback.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Optional

import httpx

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class TranslationResult:
    """Result of translation."""
    text: str
    source_lang: str
    target_lang: str
    backend: str
    cached: bool = False


class Translator(ABC):
    """Abstract base for translation backends."""

    @abstractmethod
    async def translate(
        self,
        text: str,
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> Optional[TranslationResult]:
        """Translate text. Returns None if translation fails."""
        pass

    @abstractmethod
    async def translate_batch(
        self,
        texts: list[str],
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> list[Optional[TranslationResult]]:
        """Translate multiple texts."""
        pass


class LibreTranslateTranslator(Translator):
    """Translation using LibreTranslate API (self-hosted or public)."""

    def __init__(
        self,
        base_url: str = "https://libretranslate.de",
        api_key: Optional[str] = None,
        timeout: float = 30.0,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._timeout = timeout
        self._client: Optional[httpx.AsyncClient] = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=self._timeout)
        return self._client

    async def close(self) -> None:
        if self._client and not self._client.is_closed:
            await self._client.aclose()

    async def translate(
        self,
        text: str,
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> Optional[TranslationResult]:
        if not text or not text.strip():
            return None

        client = await self._get_client()
        payload = {
            "q": text,
            "source": source_lang or "auto",
            "target": target_lang,
            "format": "text",
        }
        if self._api_key:
            payload["api_key"] = self._api_key

        try:
            response = await client.post(
                f"{self._base_url}/translate",
                json=payload,
            )
            if response.status_code == 200:
                data = response.json()
                return TranslationResult(
                    text=data.get("translatedText", ""),
                    source_lang=data.get("detectedLanguage", source_lang or "auto"),
                    target_lang=target_lang,
                    backend="libretranslate",
                )
            logger.warning(f"LibreTranslate error: {response.status_code} - {response.text}")
            return None
        except Exception as e:
            logger.debug(f"LibreTranslate exception: {e}")
            return None

    async def translate_batch(
        self,
        texts: list[str],
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> list[Optional[TranslationResult]]:
        results = []
        for text in texts:
            results.append(await self.translate(text, source_lang, target_lang))
            await asyncio.sleep(0.1)
        return results


class GoogleTranslator(Translator):
    """Translation using Google Translate (via deep-translator)."""

    def __init__(self, timeout: float = 30.0) -> None:
        self._timeout = timeout
        self._translator = None
        self._init_translator()

    def _init_translator(self) -> None:
        try:
            from deep_translator import GoogleTranslator
            self._translator = GoogleTranslator(source="auto", target="en")
        except ImportError:
            logger.warning("deep-translator not installed; GoogleTranslator unavailable")

    async def translate(
        self,
        text: str,
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> Optional[TranslationResult]:
        if not self._translator or not text or not text.strip():
            return None

        loop = asyncio.get_event_loop()
        try:
            if source_lang and source_lang != "auto":
                self._translator.source = source_lang
            self._translator.target = target_lang

            translated = await loop.run_in_executor(
                None,
                lambda: self._translator.translate(text[:5000]),
            )
            return TranslationResult(
                text=translated,
                source_lang=source_lang or "auto",
                target_lang=target_lang,
                backend="google",
            )
        except Exception as e:
            logger.debug(f"GoogleTranslator error: {e}")
            return None

    async def translate_batch(
        self,
        texts: list[str],
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> list[Optional[TranslationResult]]:
        results = []
        for text in texts:
            results.append(await self.translate(text, source_lang, target_lang))
            await asyncio.sleep(0.05)
        return results


class MyMemoryTranslator(Translator):
    """Translation using MyMemory API (free, generous limits)."""

    def __init__(
        self,
        email: Optional[str] = None,
        timeout: float = 30.0,
    ) -> None:
        self._email = email or os.getenv("MYMEMORY_EMAIL")
        self._timeout = timeout
        self._client: Optional[httpx.AsyncClient] = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=self._timeout)
        return self._client

    async def close(self) -> None:
        if self._client and not self._client.is_closed:
            await self._client.aclose()

    async def translate(
        self,
        text: str,
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> Optional[TranslationResult]:
        if not text or not text.strip():
            return None

        client = await self._get_client()
        params = {
            "q": text[:5000],
            "langpair": f"{source_lang or 'auto'}|{target_lang}",
        }
        if self._email:
            params["de"] = self._email

        try:
            response = await client.get(
                "https://api.mymemory.translated.net/get",
                params=params,
            )
            if response.status_code == 200:
                data = response.json()
                translated = data.get("responseData", {}).get("translatedText", "")
                if translated and translated != text:
                    return TranslationResult(
                        text=translated,
                        source_lang=source_lang or "auto",
                        target_lang=target_lang,
                        backend="mymemory",
                    )
            return None
        except Exception as e:
            logger.debug(f"MyMemoryTranslator error: {e}")
            return None

    async def translate_batch(
        self,
        texts: list[str],
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> list[Optional[TranslationResult]]:
        results = []
        for text in texts:
            results.append(await self.translate(text, source_lang, target_lang))
            await asyncio.sleep(0.2)
        return results


class CachedTranslator(Translator):
    """Wrapper that caches translations in memory."""

    def __init__(self, translator: Translator, max_cache_size: int = 1000) -> None:
        self._translator = translator
        self._cache: dict[str, TranslationResult] = {}
        self._max_cache_size = max_cache_size

    def _cache_key(
        self,
        text: str,
        source_lang: Optional[str],
        target_lang: str,
    ) -> str:
        return f"{source_lang or 'auto'}>{target_lang}:{hash(text)}"

    async def translate(
        self,
        text: str,
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> Optional[TranslationResult]:
        key = self._cache_key(text, source_lang, target_lang)
        if key in self._cache:
            cached = self._cache[key]
            return TranslationResult(
                text=cached.text,
                source_lang=cached.source_lang,
                target_lang=cached.target_lang,
                backend=cached.backend,
                cached=True,
            )

        result = await self._translator.translate(text, source_lang, target_lang)
        if result:
            if len(self._cache) >= self._max_cache_size:
                self._cache.clear()
            self._cache[key] = result
        return result

    async def translate_batch(
        self,
        texts: list[str],
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> list[Optional[TranslationResult]]:
        return await self._translator.translate_batch(texts, source_lang, target_lang)

    async def close(self) -> None:
        if hasattr(self._translator, "close"):
            await self._translator.close()


class CompositeTranslator(Translator):
    """Composite translator that tries multiple backends in order."""

    def __init__(self, translators: list[Translator]) -> None:
        self._translators = translators

    async def translate(
        self,
        text: str,
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> Optional[TranslationResult]:
        for translator in self._translators:
            result = await translator.translate(text, source_lang, target_lang)
            if result and result.text and result.text != text:
                return result
        return None

    async def translate_batch(
        self,
        texts: list[str],
        source_lang: Optional[str] = None,
        target_lang: str = "en",
    ) -> list[Optional[TranslationResult]]:
        results: list[Optional[TranslationResult]] = [None] * len(texts)
        for translator in self._translators:
            for i, text in enumerate(texts):
                if results[i] is None:
                    result = await translator.translate(text, source_lang, target_lang)
                    if result and result.text and result.text != text:
                        results[i] = result
        return results

    async def close(self) -> None:
        for t in self._translators:
            if hasattr(t, "close"):
                await t.close()


def create_translator(
    backends: list[str] = None,
    libretranslate_url: str = "https://libretranslate.de",
    libretranslate_key: Optional[str] = None,
    mymemory_email: Optional[str] = None,
    timeout: float = 30.0,
    use_cache: bool = True,
) -> Translator:
    """Create a composite translator with specified backends.

    Parameters
    ----------
    backends : list[str], optional
        Ordered list of backend names: "libretranslate", "google", "mymemory"
        Defaults to all available.
    libretranslate_url : str
        Base URL for LibreTranslate instance.
    libretranslate_key : str, optional
        API key for LibreTranslate.
    mymemory_email : str, optional
        Email for MyMemory API (increases rate limits).
    timeout : float
        Request timeout in seconds.
    use_cache : bool
        Whether to wrap in CachedTranslator.

    Returns
    -------
    Translator
        Configured translator instance.
    """
    if backends is None:
        backends = ["libretranslate", "google", "mymemory"]

    translators: list[Translator] = []

    if "libretranslate" in backends:
        translators.append(LibreTranslateTranslator(
            base_url=libretranslate_url,
            api_key=libretranslate_key,
            timeout=timeout,
        ))

    if "google" in backends:
        translators.append(GoogleTranslator(timeout=timeout))

    if "mymemory" in backends:
        translators.append(MyMemoryTranslator(
            email=mymemory_email,
            timeout=timeout,
        ))

    if not translators:
        translators.append(LibreTranslateTranslator(timeout=timeout))

    composite = CompositeTranslator(translators)

    if use_cache:
        return CachedTranslator(composite)

    return composite