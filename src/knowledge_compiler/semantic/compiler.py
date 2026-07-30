"""Semantic compiler — unstructured text → Entity-Relationship triplets.

Extracts (E1, R, E2) triples from raw text using lightweight NLP
heuristics.  Designed as a pluggable module so that an embedded LLM
pipeline can replace the rule-based extractor without touching any
other component.

Complexity
----------
- Sentence segmentation: O(N) where N = character count.
- Triplet extraction: O(S * W) where S = sentence count, W = average
  words per sentence.
- Overall: O(N) in practice (single-pass text processing).
"""

from __future__ import annotations

import re

from ..telemetry import EventBus

ER_Triplet = tuple[str, str, str]

RELATION_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("is_a", re.compile(r"(\w+(?:\s+\w+)*)\s+is\s+(?:a(?:n)?\s+)?(\w+(?:\s+\w+)*)", re.IGNORECASE)),
    ("has", re.compile(r"(\w+(?:\s+\w+)*)\s+has\s+(\w+(?:\s+\w+)*)", re.IGNORECASE)),
    ("defines", re.compile(r"(\w+(?:\s+\w+)*)\s+defines\s+(\w+(?:\s+\w+)*)", re.IGNORECASE)),
    ("causes", re.compile(r"(\w+(?:\s+\w+)*)\s+causes\s+(\w+(?:\s+\w+)*)", re.IGNORECASE)),
    ("part_of", re.compile(r"(\w+(?:\s+\w+)*)\s+is\s+part\s+of\s+(\w+(?:\s+\w+)*)", re.IGNORECASE)),
    (
        "related_to",
        re.compile(
            r"(\w+(?:\s+\w+)*)\s+(?:relates\s+to|related\s+to)\s+(\w+(?:\s+\w+)*)",
            re.IGNORECASE,
        ),
    ),
]


class SemanticCompiler:
    """Rule-based ER triplet extractor.

    Parameters
    ----------
    event_bus : EventBus
        Telemetry sink for extraction events.
    """

    __slots__ = ("_event_bus",)

    def __init__(self, event_bus: EventBus) -> None:
        self._event_bus = event_bus

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def compile(self, text: str, source_url: str = "") -> list[ER_Triplet]:
        """Extract ER triplets from *text*.

        Parameters
        ----------
        text : str
            Raw unstructured text.
        source_url : str
            Provenance URL stored in telemetry.

        Returns
        -------
        list[(str, str, str)]
            Each triplet is (entity_1, relation, entity_2).
        """
        sentences = _segment_sentences(text)
        triplets: list[ER_Triplet] = []

        for sentence in sentences:
            for rel_name, pattern in RELATION_PATTERNS:
                for match in pattern.finditer(sentence):
                    e1 = match.group(1).strip().lower()
                    e2 = match.group(2).strip().lower()
                    if len(e1) > 2 and len(e2) > 2 and len(e1) < 80 and len(e2) < 80:
                        triplets.append((e1, rel_name, e2))

        self._event_bus.emit(
            "semantic:triplets_extracted",
            "SemanticCompiler",
            {
                "source": source_url,
                "text_chars": len(text),
                "sentences": len(sentences),
                "triplets": len(triplets),
            },
            version="v2",
        )

        return triplets


def _segment_sentences(text: str) -> list[str]:
    """Split *text* into sentences on standard punctuation boundaries.

    Complexity: O(N) single-pass scan.
    """
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if len(s.strip()) > 10]
