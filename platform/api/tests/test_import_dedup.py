"""Import, provenance and reversible deduplication against the synthetic ground truth."""
from conftest import SYNTH, by_title, import_synthetic

from app.parsers import parse_bibtex, parse_csv, parse_ris


def test_parsers_report_failures_instead_of_dropping():
    entries, failures = parse_ris("TY  - JOUR\nTI  - ok\nPY  - 2020\nER  -\nTY  - JOUR\nTI  - no end\n")
    assert len(entries) == 1 and len(failures) == 1
    entries, failures = parse_bibtex("@article{a, title={Good}, year={2020}}\n@article{b, title={Broken, year={2020}\n")
    assert len(entries) == 1 and len(failures) == 1
    entries, failures = parse_csv("title,year\nA,2020\nB,2021,extra\n")
    assert len(entries) == 1 and failures[0]["position"] == 3


def test_import_keeps_every_source_record_and_refuses_the_same_file_twice(client, users):
    lead = users["lead"]
    rid = lead.post("/reviews", json={"title": "t"}).json()["id"]
    summaries = import_synthetic(lead, rid)
    assert [s["imported"] for s in summaries] == [5, 4, 2, 2]
    assert all(s["failed"] == 0 for s in summaries)
    assert len(lead.get(f"/reviews/{rid}/publications").json()) == 13
    with open(SYNTH / "rayyan-test-medline.ris", "rb") as fh:
        r = lead.post(f"/reviews/{rid}/imports", files={"file": ("again.ris", fh.read())})
    assert r.status_code == 409 and r.json()["error"] == "already_imported"
    detail = lead.get(f"/reviews/{rid}/publications/1").json()
    assert detail["source_records"][0]["raw_text"].startswith("TY  - JOUR")


def test_dedup_matches_ground_truth(client, users):
    lead = users["lead"]
    rid = lead.post("/reviews", json={"title": "t"}).json()["id"]
    import_synthetic(lead, rid)
    lead.post(f"/reviews/{rid}/dedup/detect")
    cands = lead.get(f"/reviews/{rid}/dedup/candidates").json()
    titles = lambda c: (c["title_a"], c["title_b"])  # noqa: E731
    # Epsilon (a correction) is never paired with Alpha.
    assert not any("Epsilon" in " ".join(titles(c)) for c in cands)
    # The Delta conference abstract is a candidate, but blocked as a different kind of publication.
    delta = [c for c in cands if "Delta" in c["title_a"] and "different_kind" in c["blockers"]]
    assert len(delta) == 2
    # Beta has no shared identifier: only the title rule finds it, so it is not auto-merged.
    beta = [c for c in cands if "Beta" in c["title_a"]]
    assert [c["rule"] for c in beta] == ["title_year"]

    auto = lead.post(f"/reviews/{rid}/dedup/auto-merge").json()
    assert len(auto["merged"]) >= 3
    assert len(lead.get(f"/reviews/{rid}/publications").json()) == 10   # Beta still two
    lead.post(f"/reviews/{rid}/dedup/candidates/{beta[0]['id']}/merge")
    pubs = lead.get(f"/reviews/{rid}/publications").json()
    assert len(pubs) == 9
    ids = by_title(lead, rid)
    alpha = next(p for p in pubs if p["id"] == ids["Alpha"])
    assert len(alpha["source_records"]) == 3

    # Studies: Delta article + abstract are one study; Epsilon is attached to Alpha -> 7 studies.
    for key, pid in ids.items():
        if key in ("Delta abstract", "Epsilon"):
            continue
        sec = [ids["Delta abstract"]] if key == "Delta" else [ids["Epsilon"]] if key == "Alpha" else []
        assert lead.post(f"/reviews/{rid}/studies", json={"label": key, "primary_publication_id": pid,
                                                           "secondary_publication_ids": sec}).status_code == 201
    assert lead.get(f"/reviews/{rid}/prisma").json()["studies"] == 7
    pr = lead.get(f"/reviews/{rid}/prisma").json()
    assert pr["records_identified"] == 13 and pr["duplicates_removed"] == 4


def test_merge_then_split_restores_original_grouping(client, users):
    lead = users["lead"]
    rid = lead.post("/reviews", json={"title": "t"}).json()["id"]
    import_synthetic(lead, rid)
    before = {p["id"]: p["source_records"] for p in lead.get(f"/reviews/{rid}/publications").json()}
    lead.post(f"/reviews/{rid}/dedup/detect")
    lead.post(f"/reviews/{rid}/dedup/auto-merge")
    alpha = next(p for p in lead.get(f"/reviews/{rid}/publications").json() if p["doi_norm"] == "10.99999/synthetic.0001")
    assert len(alpha["source_records"]) == 3
    for sr in alpha["source_records"][1:]:
        r = lead.post(f"/reviews/{rid}/publications/{alpha['id']}/split", json={"source_record_id": sr})
        assert r.status_code == 200, r.text
    after = {p["id"]: p["source_records"] for p in lead.get(f"/reviews/{rid}/publications").json()}
    for pid in (alpha["id"], *[k for k, v in before.items() if v[0] in alpha["source_records"][1:]]):
        assert after[pid] == before[pid]
    # History is kept: the old links are still there, marked as unlinked.
    with __import__("psycopg").connect(client.db_url) as c:
        n = c.execute("select count(*) from rp.publication_sources where unlinked_at is not null").fetchone()[0]
    assert n >= 4
