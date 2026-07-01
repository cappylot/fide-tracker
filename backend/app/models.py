"""
Database models shared by the ingestion worker and the API.

Two long-lived tables plus a small ingestion log:

  Player          – one row per FIDE-ID. Mutable identity fields (name,
                    federation, title) are overwritten on every import so a
                    federation change or name change never breaks history,
                    because the FIDE-ID (the primary key) is stable.

  RatingSnapshot  – one row per (player, rating-period). This is the history.
                    Deltas are NOT stored; they are computed on the fly from
                    two snapshots (see api/routers). Unique on (fide_id, period)
                    so re-running an import for the same month is idempotent.

  IngestionRun    – audit log; also lets us skip a download whose SHA-256 we
                    have already imported.

The same models run on SQLite (local dev) and PostgreSQL (Supabase in prod);
DATABASE_URL decides which.
"""
from __future__ import annotations

import os
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    DateTime,
    Index,
    Integer,
    String,
    UniqueConstraint,
    create_engine,
    func,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:///fide.db")

# psycopg v3 uses the "postgresql+psycopg" dialect; accept a plain
# "postgres://" URL (what Supabase / Heroku hand out) and normalise it.
if DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+psycopg://", 1)
elif DATABASE_URL.startswith("postgresql://"):
    DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+psycopg://", 1)

_connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, pool_pre_ping=True, connect_args=_connect_args)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


class Player(Base):
    __tablename__ = "player"

    fide_id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    name: Mapped[str] = mapped_column(String(128), index=True)
    federation: Mapped[str | None] = mapped_column(String(3), index=True)
    sex: Mapped[str | None] = mapped_column(String(1))
    title: Mapped[str | None] = mapped_column(String(4))
    w_title: Mapped[str | None] = mapped_column(String(4))
    o_title: Mapped[str | None] = mapped_column(String(16))
    birth_year: Mapped[int | None] = mapped_column(Integer)
    # FIDE inactivity flag: "i"/"wi" (inactive), "w" (woman). Empty = active.
    flag: Mapped[str | None] = mapped_column(String(4))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class RatingSnapshot(Base):
    __tablename__ = "rating_snapshot"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    fide_id: Mapped[int] = mapped_column(BigInteger, index=True)
    period: Mapped[str] = mapped_column(String(7))  # "YYYY-MM"

    standard: Mapped[int | None] = mapped_column(Integer)
    rapid: Mapped[int | None] = mapped_column(Integer)
    blitz: Mapped[int | None] = mapped_column(Integer)
    standard_games: Mapped[int | None] = mapped_column(Integer)
    rapid_games: Mapped[int | None] = mapped_column(Integer)
    blitz_games: Mapped[int | None] = mapped_column(Integer)

    __table_args__ = (
        UniqueConstraint("fide_id", "period", name="uq_snapshot_player_period"),
        Index("ix_snapshot_period", "period"),
    )


class IngestionRun(Base):
    __tablename__ = "ingestion_run"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    period: Mapped[str] = mapped_column(String(7))
    source_sha256: Mapped[str] = mapped_column(String(64), index=True)
    player_count: Mapped[int] = mapped_column(Integer, default=0)
    finished_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


def init_db() -> None:
    Base.metadata.create_all(engine)
