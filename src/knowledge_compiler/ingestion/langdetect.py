"""Language detection for scraped content.

Supports multiple backends with graceful fallback.
"""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Optional

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class LanguageResult:
    """Result of language detection."""
    code: str
    name: str
    confidence: float
    backend: str


class LanguageDetector(ABC):
    """Abstract base for language detection backends."""

    @abstractmethod
    def detect(self, text: str) -> Optional[LanguageResult]:
        """Detect language of text. Returns None if detection fails."""
        pass

    @abstractmethod
    def detect_batch(self, texts: list[str]) -> list[Optional[LanguageResult]]:
        """Detect languages for multiple texts."""
        pass


class LangDetectDetector(LanguageDetector):
    """Language detection using langdetect library."""

    def __init__(self) -> None:
        self._available = False
        try:
            from langdetect import detect, detect_langs, LangDetectException
            self._detect = detect
            self._detect_langs = detect_langs
            self._LangDetectException = LangDetectException
            self._available = True
        except ImportError:
            logger.warning("langdetect not installed; language detection unavailable")

    def detect(self, text: str) -> Optional[LanguageResult]:
        if not self._available or not text or len(text.strip()) < 20:
            return None
        try:
            lang_code = self._detect(text)
            langs = self._detect_langs(text)
            confidence = langs[0].prob if langs else 0.0
            return LanguageResult(
                code=lang_code,
                name=self._code_to_name(lang_code),
                confidence=confidence,
                backend="langdetect",
            )
        except self._LangDetectException:
            return None
        except Exception as e:
            logger.debug(f"langdetect error: {e}")
            return None

    def detect_batch(self, texts: list[str]) -> list[Optional[LanguageResult]]:
        return [self.detect(t) for t in texts]

    @staticmethod
    def _code_to_name(code: str) -> str:
        names = {
            "en": "English", "es": "Spanish", "fr": "French", "de": "German",
            "it": "Italian", "pt": "Portuguese", "ru": "Russian", "zh": "Chinese",
            "ja": "Japanese", "ko": "Korean", "ar": "Arabic", "hi": "Hindi",
            "nl": "Dutch", "pl": "Polish", "tr": "Turkish", "sv": "Swedish",
            "da": "Danish", "no": "Norwegian", "fi": "Finnish", "cs": "Czech",
            "hu": "Hungarian", "ro": "Romanian", "bg": "Bulgarian", "hr": "Croatian",
            "sk": "Slovak", "sl": "Slovenian", "et": "Estonian", "lv": "Latvian",
            "lt": "Lithuanian", "el": "Greek", "he": "Hebrew", "th": "Thai",
            "vi": "Vietnamese", "id": "Indonesian", "ms": "Malay", "tl": "Filipino",
        }
        return names.get(code, code.upper())


class FastTextDetector(LanguageDetector):
    """Language detection using fastText (more accurate, requires model file)."""

    def __init__(self, model_path: Optional[str] = None) -> None:
        self._available = False
        self._model = None
        if model_path:
            try:
                import fasttext
                self._model = fasttext.load_model(model_path)
                self._available = True
            except Exception as e:
                logger.warning(f"fastText model load failed: {e}")

    def detect(self, text: str) -> Optional[LanguageResult]:
        if not self._available or not text or len(text.strip()) < 10:
            return None
        try:
            text_clean = text.replace("\n", " ")[:1000]
            predictions = self._model.predict(text_clean, k=1)
            lang_code = predictions[0][0].replace("__label__", "")
            confidence = float(predictions[1][0])
            return LanguageResult(
                code=lang_code,
                name=self._code_to_name(lang_code),
                confidence=confidence,
                backend="fasttext",
            )
        except Exception as e:
            logger.debug(f"fastText error: {e}")
            return None

    def detect_batch(self, texts: list[str]) -> list[Optional[LanguageResult]]:
        if not self._available:
            return [None] * len(texts)
        results = []
        for text in texts:
            results.append(self.detect(text))
        return results

    @staticmethod
    def _code_to_name(code: str) -> str:
        return LangDetectDetector._code_to_name(code)


class CompositeDetector(LanguageDetector):
    """Composite detector that tries multiple backends in order."""

    def __init__(self, detectors: list[LanguageDetector]) -> None:
        self._detectors = detectors

    def detect(self, text: str) -> Optional[LanguageResult]:
        for detector in self._detectors:
            result = detector.detect(text)
            if result and result.confidence > 0.5:
                return result
        return None

    def detect_batch(self, texts: list[str]) -> list[Optional[LanguageResult]]:
        results = [None] * len(texts)
        for detector in self._detectors:
            for i, text in enumerate(texts):
                if results[i] is None:
                    result = detector.detect(text)
                    if result and result.confidence > 0.5:
                        results[i] = result
        return results


def create_detector(
    use_langdetect: bool = True,
    fasttext_model: Optional[str] = None,
) -> LanguageDetector:
    """Create a composite detector with available backends."""
    detectors: list[LanguageDetector] = []
    if use_langdetect:
        detectors.append(LangDetectDetector())
    if fasttext_model:
        detectors.append(FastTextDetector(fasttext_model))
    if not detectors:
        detectors.append(LangDetectDetector())
    return CompositeDetector(detectors) if len(detectors) > 1 else detectors[0]