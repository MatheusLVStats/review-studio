"""Duplicate candidates, merge, split (spec §5). Nothing is deleted; every change is logged."""
from __future__ import annotations

import itertools
import re

from .parsers import norm_title

NOTICE = re.compile(r"\b(correction|corrigendum|erratum|retraction|retracted|comment|reply|protocol)\b", re.I)


def roots(conn, review_id: int) -> list[dict]:
    return conn.execute(
        "select id, title, year, doi_norm, pmid, kind from publications where review_id = %s and merged_into is null order by id",
        (review_id,)).fetchall()


def blockers(a: dict, b: dict) -> list[str]:
    out = []
    for p in (a, b):
        if p["title"] and NOTICE.search(p["title"]):
            out.append(f"notice:{p['id']}")
    if a["kind"] != b["kind"]:
        out.append("different_kind")
    return out


def detect(conn, review_id: int) -> dict:
    pubs = roots(conn, review_id)
    found: dict[tuple[int, int], tuple[str, float]] = {}

    def add(a, b, rule, score):
        key = (min(a["id"], b["id"]), max(a["id"], b["id"]))
        if key not in found or found[key][1] < score:
            found[key] = (rule, score)

    by: dict[str, dict] = {"doi": {}, "pmid": {}, "title": {}}
    for p in pubs:
        if p["doi_norm"]:
            by["doi"].setdefault(p["doi_norm"], []).append(p)
        if p["pmid"]:
            by["pmid"].setdefault(p["pmid"], []).append(p)
        t = norm_title(p["title"])
        if t:
            by["title"].setdefault(t, []).append(p)
    for rule, score in (("doi", 1.0), ("pmid", 1.0)):
        for group in by[rule].values():
            for a, b in itertools.combinations(group, 2):
                add(a, b, rule, score)
    for group in by["title"].values():
        for a, b in itertools.combinations(group, 2):
            if a["year"] is None or b["year"] is None or abs(a["year"] - b["year"]) <= 1:
                add(a, b, "title_year", 0.9)

    index = {p["id"]: p for p in pubs}
    new = 0
    for (a, b), (rule, score) in found.items():
        row = conn.execute(
            """insert into dedup_candidates(review_id, publication_a, publication_b, rule, score, blockers)
               values (%s,%s,%s,%s,%s,%s) on conflict (review_id, publication_a, publication_b) do nothing returning id""",
            (review_id, a, b, rule, score, blockers(index[a], index[b]))).fetchone()
        new += bool(row)
    return {"pairs_found": len(found), "new_candidates": new}


def root_of(conn, pub_id: int) -> int:
    while True:
        r = conn.execute("select merged_into from publications where id = %s", (pub_id,)).fetchone()
        if r["merged_into"] is None:
            return pub_id
        pub_id = r["merged_into"]


def merge(conn, review_id: int, keep: int, drop: int, actor: int) -> dict:
    """Move the current source links of `drop` onto `keep` and mark `drop` as merged."""
    moved = conn.execute(
        """update publication_sources set unlinked_at = now(), unlinked_by = %s, unlink_reason = 'merged'
           where publication_id = %s and unlinked_at is null returning source_record_id""",
        (actor, drop)).fetchall()
    for m in moved:
        conn.execute(
            """insert into publication_sources(review_id, publication_id, source_record_id, linked_by, link_reason)
               values (%s,%s,%s,%s,'merge')""", (review_id, keep, m["source_record_id"], actor))
    conn.execute("update publications set merged_into = %s where id = %s", (keep, drop))
    return {"kept": keep, "merged": drop, "source_records_moved": [m["source_record_id"] for m in moved]}


def split(conn, review_id: int, pub_id: int, source_record_id: int, actor: int) -> dict:
    """Detach one source record from a publication. Its original publication is restored if possible."""
    link = conn.execute(
        "select * from publication_sources where review_id=%s and publication_id=%s and source_record_id=%s and unlinked_at is null",
        (review_id, pub_id, source_record_id)).fetchone()
    if not link:
        return {"error": "not_linked"}
    n_links = conn.execute(
        "select count(*) n from publication_sources where publication_id=%s and unlinked_at is null", (pub_id,)).fetchone()["n"]
    if n_links < 2:
        return {"error": "last_source"}
    conn.execute("update publication_sources set unlinked_at=now(), unlinked_by=%s, unlink_reason='split' where id=%s",
                 (actor, link["id"]))
    orig = conn.execute(
        """select publication_id from publication_sources where source_record_id=%s and link_reason='import' order by id limit 1""",
        (source_record_id,)).fetchone()["publication_id"]
    has_links = conn.execute("select 1 from publication_sources where publication_id=%s and unlinked_at is null", (orig,)).fetchone()
    if orig != pub_id and not has_links:
        conn.execute("update publications set merged_into = null where id = %s", (orig,))
        target = orig
    else:
        p = conn.execute("select * from publications where id=%s", (orig,)).fetchone()
        target = conn.execute(
            """insert into publications(review_id,title,abstract,year,doi_norm,pmid,journal,authors,kind)
               values (%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
            (review_id, p["title"], p["abstract"], p["year"], p["doi_norm"], p["pmid"], p["journal"], p["authors"], p["kind"])).fetchone()["id"]
    conn.execute("""insert into publication_sources(review_id, publication_id, source_record_id, linked_by, link_reason)
                    values (%s,%s,%s,%s,'split')""", (review_id, target, source_record_id, actor))
    a, b = sorted((root_of(conn, pub_id), target))
    conn.execute("""update dedup_candidates set status='rejected', decided_by=%s, decided_at=now()
                    where review_id=%s and publication_a=%s and publication_b=%s""", (actor, review_id, a, b))
    return {"publication": pub_id, "source_record": source_record_id, "now_in_publication": target}
