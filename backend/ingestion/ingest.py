"""
Monthly ingestion entrypoint.

    python -m ingestion.ingest                # download the live FIDE list
    python -m ingestion.ingest --file a.xml   # ingest a local XML (testing)
    python -m ingestion.ingest --period 2026-06 --file a.xml

Steps:
  1. Download the latest FIDE zip (unless --file given) and hash it.
  2. If that exact SHA-256 was already imported, stop — nothing changed.
  3. Stream-parse the XML, bulk-upsert players and this period's snapshots
     in chunks. Both upserts are idempotent (ON CONFLICT), so a re-run for
     the same month is safe.
  4. Record the run in ingestion_run.

Run it from a cron job or, in production, from the GitHub Action in
.github/workflows/ingest.yml pointed at your Postgres via DATABASE_URL.
"""
from __future__ import annotations

import argparse
import sys
from itertools import islice
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

# Allow "python -m ingestion.ingest" and "python ingest.py" both to import app.*
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.models import (  # noqa: E402
    IngestionRun,
    Player,
    RatingSnapshot,
    SessionLocal,
    engine,
    init_db,
)
from ingestion.fide_client import (  # noqa: E402
    download_latest,
    fetch_last_modified,
    period_from_last_modified,
)
from ingestion.parser import iter_players  # noqa: E402

CHUNK = 5000
PLAYER_COLS = (
    "fide_id", "name", "federation", "sex",
    "title", "w_title", "o_title", "birth_year", "flag",
)
SNAPSHOT_COLS = (
    "standard", "rapid", "blitz",
    "standard_games", "rapid_games", "blitz_games",
)


def _chunks(iterable, size):
    it = iter(iterable)
    while batch := list(islice(it, size)):
        yield batch


def _upsert(session, table, rows, index_elements, update_cols):
    """Dialect-aware ON CONFLICT DO UPDATE (Postgres + SQLite)."""
    if not rows:
        return
    dialect = engine.dialect.name
    insert = pg_insert if dialect == "postgresql" else sqlite_insert
    stmt = insert(table).values(rows)
    stmt = stmt.on_conflict_do_update(
        index_elements=index_elements,
        set_={c: stmt.excluded[c] for c in update_cols},
    )
    session.execute(stmt)


def _already_imported(session, sha256: str) -> bool:
    return session.scalar(
        select(IngestionRun).where(IngestionRun.source_sha256 == sha256)
    ) is not None


def ingest_xml(xml_path: Path, period: str, sha256: str) -> int:
    count = 0
    with SessionLocal() as session:
        for batch in _chunks(iter_players(xml_path), CHUNK):
            batch = [p for p in batch if p.get("fide_id")]
            if not batch:
                continue

            _upsert(
                session,
                Player.__table__,
                [{k: p[k] for k in PLAYER_COLS} for p in batch],
                index_elements=["fide_id"],
                update_cols=[c for c in PLAYER_COLS if c != "fide_id"],
            )
            _upsert(
                session,
                RatingSnapshot.__table__,
                [{"fide_id": p["fide_id"], "period": period,
                  **{k: p[k] for k in SNAPSHOT_COLS}} for p in batch],
                index_elements=["fide_id", "period"],
                update_cols=list(SNAPSHOT_COLS),
            )
            count += len(batch)
            session.commit()
            print(f"  ...{count:,} players", end="\r", flush=True)

        session.add(IngestionRun(period=period, source_sha256=sha256, player_count=count))
        session.commit()

    print(f"\nImported {count:,} players for period {period}.")
    return count


def main() -> None:
    ap = argparse.ArgumentParser(description="Ingest a FIDE rating list.")
    ap.add_argument("--file", type=Path, help="Local XML to ingest instead of downloading.")
    ap.add_argument("--period", help="Override the YYYY-MM period label.")
    ap.add_argument("--force", action="store_true", help="Import even if the hash is known.")
    ap.add_argument(
        "--print-period",
        action="store_true",
        help="Print the current FIDE list's YYYY-MM period and exit (used by CI).",
    )
    args = ap.parse_args()

    # Cheap pre-check for CI: determine the period without a full import.
    if args.print_period:
        period = period_from_last_modified(fetch_last_modified())
        if period is None:
            # HEAD gave no Last-Modified; fall back to a full download to read it.
            period = download_latest().period
        print(period)
        return

    init_db()

    if args.file:
        import hashlib
        sha = hashlib.sha256(args.file.read_bytes()).hexdigest()
        period = args.period or "manual"
        xml_path = args.file
    else:
        print("Downloading latest FIDE list...")
        result = download_latest()
        sha, period = result.sha256, (args.period or result.period)
        xml_path = result.xml_path
        print(f"Downloaded {result.size_bytes/1e6:.1f} MB, period {period}, sha {sha[:12]}")

    with SessionLocal() as s:
        if not args.force and _already_imported(s, sha):
            print("This exact list was already imported — nothing to do.")
            return

    ingest_xml(xml_path, period, sha)


if __name__ == "__main__":
    main()
