"""Database access: one connection and one transaction per request."""
from __future__ import annotations

import os
import pathlib

import psycopg
from psycopg.rows import dict_row

MIGRATIONS = pathlib.Path(__file__).resolve().parents[2] / "db" / "migrations"


def dsn() -> str:
    return os.environ.get("DATABASE_URL", "postgresql://postgres@localhost:5432/review_platform")


def connect(url: str | None = None) -> psycopg.Connection:
    conn = psycopg.connect(url or dsn(), row_factory=dict_row, autocommit=False)
    conn.execute("set search_path = rp, public")
    return conn


def migrate(url: str | None = None) -> list[str]:
    """Apply numbered .sql files that have not been applied yet. Returns the names applied."""
    applied = []
    with psycopg.connect(url or dsn(), autocommit=True) as conn:
        conn.execute("create table if not exists public.schema_migrations (name text primary key, applied_at timestamptz not null default now())")
        done = {r[0] for r in conn.execute("select name from public.schema_migrations")}
        for path in sorted(MIGRATIONS.glob("*.sql")):
            if path.name in done:
                continue
            with conn.transaction():
                conn.execute(path.read_text())
                conn.execute("insert into public.schema_migrations(name) values (%s)", (path.name,))
            applied.append(path.name)
    return applied


if __name__ == "__main__":
    print("applied:", migrate() or "nothing new")
