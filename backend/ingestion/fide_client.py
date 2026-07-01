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

# Archived per-type monthly lists, e.g. standard_jan25frl_xml.zip. Unlike the
# combined list above, each archive carries a single <rating>/<games> pair for
# its own rating type.
ARCHIVE_URL_TEMPLATE = "https://ratings.fide.com/download/{kind}_{mon}{yy}frl_xml.zip"
MONTH_ABBR = ("jan", "feb", "mar", "apr", "may", "jun",
              "jul", "aug", "sep", "oct", "nov", "dec")


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


def _extract_first_xml(raw: bytes, dest_dir: Path) -> Path:
    """Extract the first .xml member of a zip (FIDE zips hold exactly one,
    but we match by extension defensively in case the filename changes)."""
    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        xml_name = next(n for n in zf.namelist() if n.lower().endswith(".xml"))
        zf.extract(xml_name, dest_dir)
        return dest_dir / xml_name


def download_latest(dest_dir: Path | None = None, url: str = FIDE_XML_ZIP_URL) -> DownloadResult:
    dest_dir = Path(dest_dir or tempfile.mkdtemp(prefix="fide_"))
    dest_dir.mkdir(parents=True, exist_ok=True)

    with requests.get(url, headers={"User-Agent": USER_AGENT}, stream=True, timeout=300) as resp:
        resp.raise_for_status()
        period = _period_from_headers(resp.headers)
        raw = resp.content  # ~40-50 MB zip; fine to hold in memory once

    return DownloadResult(
        xml_path=_extract_first_xml(raw, dest_dir),
        sha256=hashlib.sha256(raw).hexdigest(),
        period=period,
        size_bytes=len(raw),
    )


def archive_url(kind: str, period: str) -> str:
    """URL of the archived list of one kind ('standard' | 'rapid' | 'blitz')
    for a 'YYYY-MM' period, e.g. ('standard', '2025-01') ->
    .../standard_jan25frl_xml.zip"""
    year, month = period.split("-")
    return ARCHIVE_URL_TEMPLATE.format(
        kind=kind, mon=MONTH_ABBR[int(month) - 1], yy=year[-2:]
    )


def download_archive(kind: str, period: str, dest_dir: Path | None = None) -> DownloadResult | None:
    """Download one archived monthly list, or None if FIDE hasn't published
    an archive for that period (404)."""
    url = archive_url(kind, period)
    with requests.get(url, headers={"User-Agent": USER_AGENT}, stream=True, timeout=300) as resp:
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        raw = resp.content  # ~5-15 MB per archive zip

    dest_dir = Path(dest_dir or tempfile.mkdtemp(prefix=f"fide_{kind}_"))
    dest_dir.mkdir(parents=True, exist_ok=True)

    return DownloadResult(
        xml_path=_extract_first_xml(raw, dest_dir),
        sha256=hashlib.sha256(raw).hexdigest(),
        period=period,
        size_bytes=len(raw),
    )
