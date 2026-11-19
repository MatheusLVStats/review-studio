"""Each test gets a fresh database copied from a migrated template.

Set TEST_DATABASE_ADMIN_URL to a Postgres server where the test user may create databases,
e.g. postgresql://postgres@localhost:5432/postgres
"""
from __future__ import annotations

import os
import pathlib
import uuid

import psycopg
import psycopg.conninfo
import pytest
from fastapi.testclient import TestClient

ADMIN = os.environ.get("TEST_DATABASE_ADMIN_URL", "postgresql://postgres@localhost:5432/postgres")
TEMPLATE = "rp_test_template"
SYNTH = pathlib.Path(__file__).resolve().parents[3] / "test-data" / "synthetic"


def _url(dbname: str) -> str:
    return psycopg.conninfo.make_conninfo(ADMIN, dbname=dbname)


@pytest.fixture(scope="session")
def template_db():
    from app import db
    with psycopg.connect(ADMIN, autocommit=True) as c:
        c.execute(f"drop database if exists {TEMPLATE}")
        c.execute(f"create database {TEMPLATE}")
    db.migrate(_url(TEMPLATE))
    yield TEMPLATE
    with psycopg.connect(ADMIN, autocommit=True) as c:
        c.execute(f"drop database if exists {TEMPLATE} with (force)")


@pytest.fixture()
def client(template_db, tmp_path, monkeypatch):
    name = "rp_test_" + uuid.uuid4().hex[:10]
    with psycopg.connect(ADMIN, autocommit=True) as c:
        c.execute(f"create database {name} template {template_db}")
    monkeypatch.setenv("DATABASE_URL", _url(name))
    from app import main
    monkeypatch.setattr(main, "FILES_DIR", tmp_path / "files")
    with TestClient(main.app) as tc:
        tc.db_url = _url(name)
        yield tc
    with psycopg.connect(ADMIN, autocommit=True) as c:
        c.execute(f"drop database if exists {name} with (force)")


class User:
    def __init__(self, client, name: str):
        self.c = client
        self.email = f"{name}@example.test"
        r = client.post("/auth/register", json={"email": self.email, "display_name": name, "password": "correct horse " + name})
        assert r.status_code == 201, r.text
        self.id = r.json()["id"]
        r = client.post("/auth/login", json={"email": self.email, "password": "correct horse " + name})
        assert r.status_code == 200, r.text
        self.h = {"Authorization": "Bearer " + r.json()["token"]}

    def get(self, path, **kw):
        return self.c.get(path, headers=self.h, **kw)

    def post(self, path, **kw):
        return self.c.post(path, headers=self.h, **kw)

    def patch(self, path, **kw):
        return self.c.patch(path, headers=self.h, **kw)

    def delete(self, path, **kw):
        return self.c.delete(path, headers=self.h, **kw)


@pytest.fixture()
def users(client):
    return {n: User(client, n) for n in ("lead", "ana", "bruno", "viewer", "outsider")}


def import_synthetic(u: User, rid: int) -> list[dict]:
    out = []
    for fn in ("rayyan-test-medline.ris", "rayyan-test-embase.ris", "rayyan-test-central.bib", "rayyan-test-registry.csv"):
        with open(SYNTH / fn, "rb") as fh:
            r = u.post(f"/reviews/{rid}/imports", files={"file": (fn, fh.read())})
        assert r.status_code == 201, r.text
        out.append(r.json())
    return out


def by_title(u: User, rid: int) -> dict[str, int]:
    """Map a distinctive word of each synthetic title to its current publication id."""
    pubs = u.get(f"/reviews/{rid}/publications").json()
    m = {}
    for p in pubs:
        t = p["title"]
        key = ("Delta abstract" if p["kind"] == "conference" else
               "Epsilon" if "Epsilon" in t else
               next(w for w in ("Alpha", "Beta", "Gamma", "Delta", "Zeta", "Eta", "Theta") if f" {w} " in t))
        assert key not in m, f"two current publications for {key}"
        m[key] = p["id"]
    return m


@pytest.fixture()
def team_review(client, users):
    """A review with members, synthetic data imported and deduplicated to 9 publications."""
    lead = users["lead"]
    rid = lead.post("/reviews", json={"title": "Synthetic test review"}).json()["id"]
    for name, role in (("ana", "reviewer"), ("bruno", "reviewer"), ("viewer", "viewer")):
        assert lead.post(f"/reviews/{rid}/members", json={"email": users[name].email, "role": role}).status_code == 201
    import_synthetic(lead, rid)
    lead.post(f"/reviews/{rid}/dedup/detect")
    lead.post(f"/reviews/{rid}/dedup/auto-merge")
    for c in lead.get(f"/reviews/{rid}/dedup/candidates", params={"status": "open"}).json():
        if not c["blockers"]:
            assert lead.post(f"/reviews/{rid}/dedup/candidates/{c['id']}/merge").status_code == 200
    return rid
