"""
One-time backfill of historical FIDE rating lists.

    python -m ingestion.backfill                  # last 24 months
    python -m ingestion.backfill --months 12
    python -m ingestion.backfill --full           # keep every row (much larger DB)

FIDE archives each month's Standard/Rapid/Blitz lists as separate zips
(e.g. standard_jan25frl_xml.zip). For every month in the window that is newer
than anything already in the database, this downloads the three lists and
upserts that month's snapshots, so the app has chart history from day one.

To keep the shipped SQLite small enough for a phone download, a snapshot row
is normally written only when a player's rating in that list changed since
the last stored month (change-points; ~24 full months would be several GB).
The two newest months of the window are always written in full, because the
app's search/top/month-delta queries expect the latest periods to be
complete. The regular monthly ingest (ingestion.ingest) writes full months
from then on.

Safe to re-run: months at or before the newest period already in the
database are skipped, so the CI job is a free no-op once history exists.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import select, text

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.models import (  # noqa: E402
    IngestionRun,
    Player,
    RatingSnapshot,
    SessionLocal,
    init_db,
)
from ingestion.fide_client import download_archive  # noqa: E402
from ingestion.ingest import CHUNK, PLAYER_COLS, _chunks, _upsert  # noqa: E402
from ingestion.parser import iter_archive_players  # noqa: E402

# (rating column, games column) fed by each archived list kind.
KIND_COLS = {
    "standard": ("standard", "standard_games"),
    "rapid": ("rapid", "rapid_games"),
    "blitz": ("blitz", "blitz_games"),
}


def _window(months: int) -> list[str]:
    """The last `months` periods as 'YYYY-MM', oldest first, ending with the
    current month (whose archive may not exist yet; that's handled)."""
    now = datetime.now(timezone.utc)
    y, m = now.year, now.month
    periods: list[str] = []
    for _ in range(months):
        periods.append(f"{y:04d}-{m:02d}")
        y, m = (y - 1, 12) if m == 1 else (y, m - 1)
    return periods[::-1]


def _seed_state(session, rating_col: str) -> dict[int, int]:
    """fide_id -> last stored rating for one list kind. Empty on a fresh DB;
    on a seeded DB it lets the first new month dedup against existing rows."""
    rows = session.execute(text(f"""
        SELECT fide_id, {rating_col} FROM (
            SELECT fide_id, {rating_col},
                   ROW_NUMBER() OVER (PARTITION BY fide_id ORDER BY period DESC) AS rn
            FROM rating_snapshot
            WHERE {rating_col} IS NOT NULL
        ) latest WHERE rn = 1
    """))
    return dict(rows.all())


def _import_list(
    session,
    period: str,
    kind: str,
    state: dict[int, int] | None,
    keep_all: bool,
    known_ids: set[int],
) -> tuple[int, str] | None:
    """Import one archived list. Returns (snapshot rows written, zip sha256),
    or None when FIDE has no archive for that period."""
    result = download_archive(kind, period)
    if result is None:
        return None

    rating_col, games_col = KIND_COLS[kind]
    written = 0
    try:
        for batch in _chunks(iter_archive_players(result.xml_path), CHUNK):
            batch = [p for p in batch if p.get("fide_id")]
            if not batch:
                continue

            # Identity fields only for players we've never seen: the regular
            # ingest refreshes metadata for everyone on the current list, so
            # historical lists must not overwrite newer names/federations.
            new_players = [p for p in batch if p["fide_id"] not in known_ids]
            if new_players:
                _upsert(
                    session,
                    Player.__table__,
                    [{k: p[k] for k in PLAYER_COLS} for p in new_players],
                    index_elements=["fide_id"],
                    update_cols=[c for c in PLAYER_COLS if c != "fide_id"],
                )
                known_ids.update(p["fide_id"] for p in new_players)

            if state is None:
                keep = batch
            else:
                changed = [p for p in batch if state.get(p["fide_id"]) != p["rating"]]
                for p in changed:
                    state[p["fide_id"]] = p["rating"]
                keep = batch if keep_all else changed

            if keep:
                _upsert(
                    session,
                    RatingSnapshot.__table__,
                    [{"fide_id": p["fide_id"], "period": period,
                      rating_col: p["rating"], games_col: p["games"]} for p in keep],
                    index_elements=["fide_id", "period"],
                    update_cols=[rating_col, games_col],
                )
                written += len(keep)
        session.commit()
    finally:
        shutil.rmtree(result.xml_path.parent, ignore_errors=True)
    return written, result.sha256


def backfill(months: int, dedup: bool = True) -> None:
    init_db()
    with SessionLocal() as session:
        existing = set(session.scalars(select(RatingSnapshot.period).distinct()))
        newest = max(existing) if existing else ""
        todo = [p for p in _window(months) if p > newest]
        if not todo:
            print(f"History through {newest} already present — nothing to backfill.")
            return

        known_ids = set(session.scalars(select(Player.fide_id)))
        state = (
            {kind: _seed_state(session, cols[0]) for kind, cols in KIND_COLS.items()}
            if dedup else None
        )

        print(f"Backfilling {len(todo)} month(s): {todo[0]} .. {todo[-1]}")
        for i, period in enumerate(todo):
            keep_all = not dedup or i >= len(todo) - 2  # newest two months stay complete
            total, sha, missing = 0, None, []
            for kind in KIND_COLS:
                res = _import_list(
                    session, period, kind,
                    state[kind] if state else None, keep_all, known_ids,
                )
                if res is None:
                    missing.append(kind)
                    continue
                written, list_sha = res
                total += written
                sha = sha or list_sha
                print(f"  {period} {kind}: {written:,} snapshot rows")

            if sha is None:
                print(f"  {period}: no archives published yet — skipped.")
                continue
            if missing:
                print(f"  {period}: {', '.join(missing)} list(s) unavailable.")
            session.add(IngestionRun(period=period, source_sha256=sha, player_count=total))
            session.commit()

    print("Backfill complete.")


def main() -> None:
    ap = argparse.ArgumentParser(description="Backfill historical FIDE rating lists.")
    ap.add_argument("--months", type=int, default=24,
                    help="Window size, ending at the current month (default 24).")
    ap.add_argument("--full", action="store_true",
                    help="Store every player each month instead of only rating "
                         "changes. The database gets several times larger.")
    args = ap.parse_args()
    backfill(args.months, dedup=not args.full)


if __name__ == "__main__":
    main()
