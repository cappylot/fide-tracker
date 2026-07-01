"""
Streaming parser for the FIDE players list XML.

The uncompressed list is large (hundreds of MB, ~1M player elements including
inactive players), so we parse with iterparse and free each element as we go
instead of building a full DOM. Yields plain dicts.

FIDE per-player XML fields (confirmed):
    fideid, name, country, sex, title, w_title, o_title, foa_title,
    rating, games, k, rapid_rating, rapid_games, rapid_k,
    blitz_rating, blitz_games, blitz_k, birthday, flag
"""
from __future__ import annotations

from typing import Iterator
from xml.etree.ElementTree import iterparse


def _text(elem, tag) -> str | None:
    child = elem.find(tag)
    if child is None or child.text is None:
        return None
    value = child.text.strip()
    return value or None


def _int(elem, tag) -> int | None:
    value = _text(elem, tag)
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def iter_players(xml_path) -> Iterator[dict]:
    """Yield one dict per <player>, freeing memory as we advance."""
    context = iterparse(xml_path, events=("start", "end"))
    _, root = next(context)  # grab the root so we can clear processed children

    seen = 0
    for event, elem in context:
        if event != "end" or elem.tag != "player":
            continue

        yield {
            "fide_id": _int(elem, "fideid"),
            "name": _text(elem, "name"),
            "federation": _text(elem, "country"),
            "sex": _text(elem, "sex"),
            "title": _text(elem, "title"),
            "w_title": _text(elem, "w_title"),
            "o_title": _text(elem, "o_title"),
            "birth_year": _int(elem, "birthday"),
            "flag": _text(elem, "flag"),
            "standard": _int(elem, "rating"),
            "rapid": _int(elem, "rapid_rating"),
            "blitz": _int(elem, "blitz_rating"),
            "standard_games": _int(elem, "games"),
            "rapid_games": _int(elem, "rapid_games"),
            "blitz_games": _int(elem, "blitz_games"),
        }

        elem.clear()
        seen += 1
        if seen % 5000 == 0:
            root.clear()  # drop the accumulated (already-emitted) siblings
