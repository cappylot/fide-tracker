"""
Downloads the official monthly FIDE combined rating list and extracts the XML.

FIDE has no public API. It publishes one combined Standard/Rapid/Blitz list per
month as a zipped XML at a stable URL. We download it, hash it (to detect whether
it changed since our last run) and derive the rating period from the file's
Last-Modified date.

Source (confirmed against ratings.fide.com/download_lists.phtml):
    https://ratings.fide.com/download/players_list_xml.zip
    -> unzips to players_list_xml_foa.xml
"""
from __future__ import annotations

import hashlib
import io
import tempfile
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

import requests

FIDE_XML_ZIP_URL = "https://ratings.fide.com/download/players_list_xml.zip"
USER_AGENT = "fide-tracker/1.0 (+monthly rating-history sync)"


@dataclass
class DownloadResult:
    xml_path: Path            # extracted XML on local disk
    sha256: str               # hash of the zip we downloaded
    period: str               # "YYYY-MM" rating period
    size_bytes: int


def period_from_last_modified(last_modified: str | None) -> str | None:
    """Parse an HTTP Last-Modified header into a 'YYYY-MM' period, or None."""
    if not last_modified:
        return None
    try:
        return parsedate_to_datetime(last_modified).strftime("%Y-%m")
    except (TypeError, ValueError):
        return None


def fetch_last_modified(url: str = FIDE_XML_ZIP_URL) -> str | None:
    """Cheap HEAD request to read the list's Last-Modified header without
    downloading the body. Used by the CI pre-check to decide whether the
    monthly list is new. Returns None if the header is unavailable."""
    try:
        resp = requests.head(
            url, headers={"User-Agent": USER_AGENT}, timeout=60, allow_redirects=True
        )
        return resp.headers.get("Last-Modified")
    except requests.RequestException:
        return None


def _period_from_headers(headers) -> str:
    """Rating period from a response's Last-Modified, falling back to the
    current month if the header is missing."""
    return period_from_last_modified(headers.get("Last-Modified")) \
        or datetime.now(timezone.utc).strftime("%Y-%m")


def download_latest(dest_dir: Path | None = None, url: str = FIDE_XML_ZIP_URL) -> DownloadResult:
    dest_dir = Path(dest_dir or tempfile.mkdtemp(prefix="fide_"))
    dest_dir.mkdir(parents=True, exist_ok=True)

    with requests.get(url, headers={"User-Agent": USER_AGENT}, stream=True, timeout=300) as resp:
        resp.raise_for_status()
        period = _period_from_headers(resp.headers)
        raw = resp.content  # ~40-50 MB zip; fine to hold in memory once

    sha256 = hashlib.sha256(raw).hexdigest()

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        # The member is normally players_list_xml_foa.xml, but pick the first
        # .xml defensively in case FIDE tweaks the filename.
        xml_name = next(n for n in zf.namelist() if n.lower().endswith(".xml"))
        zf.extract(xml_name, dest_dir)
        xml_path = dest_dir / xml_name

    return DownloadResult(
        xml_path=xml_path,
        sha256=sha256,
        period=period,
        size_bytes=len(raw),
    )
