"""End-to-end flow with two reviewers, and blinding checked on every endpoint that could leak."""
import csv
import io

import psycopg
import pytest
from conftest import by_title

PLAN = {  # publication key: (ana, bruno)  -- same pair types as the Rayyan observation, plus Include+Maybe
    "Gamma": ("include", "exclude"),
    "Zeta": ("include", "include"),
    "Eta": ("exclude", "maybe"),
    "Epsilon": ("exclude", "exclude"),
    "Theta": ("include", "maybe"),
}


def setup_votes(users, rid):
    lead, ana, bruno = users["lead"], users["ana"], users["bruno"]
    r = lead.post(f"/reviews/{rid}/assignments", json={"stage": "ta", "user_ids": [ana.id, bruno.id]})
    assert r.json()["assignments_added"] == 18
    ids = by_title(lead, rid)
    return ids


def vote(u, rid, pid, decision, stage="ta", **kw):
    return u.post(f"/reviews/{rid}/publications/{pid}/votes", json={"stage": stage, "decision": decision, **kw})


def everything_ana_can_read(ana, rid, ids) -> str:
    """Concatenate every response Ana can obtain; used to search for leaks."""
    # The review settings themselves contain words like "exclude" (require_reason_ta_exclude), so they are left out.
    parts = [ana.get(f"/reviews/{rid}/screening/ta").text,
             ana.get(f"/reviews/{rid}/progress", params={"stage": "ta"}).text,
             ana.get(f"/reviews/{rid}/export", params={"stage": "ta"}).text,
             ana.get(f"/reviews/{rid}/prisma").text]
    parts += [ana.get(f"/reviews/{rid}/publications/{pid}", params={"stage": "ta"}).text for pid in ids.values()]
    return "\n".join(parts)


def test_blinded_until_reconciliation_then_resolve_and_export(client, users, team_review):
    rid = team_review
    lead, ana, bruno = users["lead"], users["ana"], users["bruno"]
    ids = setup_votes(users, rid)

    # Bruno votes first. Ana must learn nothing about it.
    for key, (_, b) in PLAN.items():
        assert vote(bruno, rid, ids[key], b).status_code == 201
    leak = everything_ana_can_read(ana, rid, ids)
    for word in ("maybe", "exclude", "conflict", '"decision"', '"votes"'):
        assert word not in leak, f"Bruno's decisions leaked to Ana ({word})"
    pr = ana.get(f"/reviews/{rid}/progress", params={"stage": "ta"}).json()
    assert pr["team_revealed"] == {} and pr["mine"] == {"pending": 9}

    for key, (a, _) in PLAN.items():
        assert vote(ana, rid, ids[key], a).status_code == 201

    # Both voted, but reconciliation is not open: still blind for both reviewers and for the lead.
    for u in (ana, bruno, lead):
        g = u.get(f"/reviews/{rid}/publications/{ids['Gamma']}").json()
        assert g["revealed"] is False and "votes" not in g
        assert u.get(f"/reviews/{rid}/progress").json()["team_revealed"] == {}
    exp = list(csv.DictReader(io.StringIO(ana.get(f"/reviews/{rid}/export").text)))
    gamma_row = next(r for r in exp if int(r["publication_id"]) == ids["Gamma"])
    assert gamma_row["current_vote:bruno"] == "[blinded]" and gamma_row["current_vote:ana"] == "include"
    assert gamma_row["final_decision"] == "" and gamma_row["status"] == "voted"
    # Lead (not assigned) sees how many votes each reviewer cast, not which.
    per = lead.get(f"/reviews/{rid}/progress").json()["per_reviewer_votes_cast"]
    assert {p["user_id"]: p["voted"] for p in per} == {ana.id: 5, bruno.id: 5}

    # Ana changes her mind on Zeta; history is kept.
    assert vote(ana, rid, ids["Zeta"], "maybe").json()["changed_previous"] is True
    assert vote(ana, rid, ids["Zeta"], "include").status_code == 201
    assert ana.get(f"/reviews/{rid}/publications/{ids['Zeta']}").json()["my_vote_changes"] == 2

    # Open reconciliation: the 5 fully voted publications are revealed, the other 4 stay blind.
    o = lead.post(f"/reviews/{rid}/stages/ta/reconciliation").json()
    assert o == {"stage": "ta", "revealed_now": 5, "still_blind_pending_votes": 4}
    g = ana.get(f"/reviews/{rid}/publications/{ids['Gamma']}").json()
    assert g["revealed"] and g["status"] == "conflict" and {v["decision"] for v in g["votes"]} == {"include", "exclude"}
    assert ana.get(f"/reviews/{rid}/publications/{ids['Alpha']}").json()["revealed"] is False
    statuses = {k: lead.get(f"/reviews/{rid}/publications/{ids[k]}").json() for k in PLAN}
    assert statuses["Zeta"]["status"] == "included"
    assert statuses["Eta"]["status"] == "conflict"          # exclude + maybe is a conflict (Rayyan shows "Maybe")
    assert statuses["Epsilon"]["status"] == "excluded"
    assert statuses["Theta"]["status"] == "included" and statuses["Theta"]["uncertain"] is True
    assert {c["publication"]["id"] for c in lead.get(f"/reviews/{rid}/stages/ta/conflicts").json()} == {ids["Gamma"], ids["Eta"]}

    # Revealed votes are locked: no changing a vote to make a conflict disappear.
    r = vote(bruno, rid, ids["Gamma"], "include")
    assert r.status_code == 409 and r.json()["error"] == "votes_locked"
    # Still-blind publications can be voted on normally.
    assert vote(ana, rid, ids["Alpha"], "include").status_code == 201

    # Resolve; the votes stay as they were.
    r = lead.post(f"/reviews/{rid}/publications/{ids['Gamma']}/resolutions",
                  json={"stage": "ta", "decision": "include", "note": "Discussed: survey may report eligible patients."})
    assert r.status_code == 201
    g = lead.get(f"/reviews/{rid}/publications/{ids['Gamma']}").json()
    assert g["final_decision"] == "include" and {v["decision"] for v in g["votes"]} == {"include", "exclude"}
    assert lead.post(f"/reviews/{rid}/publications/{ids['Zeta']}/resolutions",
                     json={"stage": "ta", "decision": "exclude", "note": "x"}).json()["error"] == "no_conflict"

    # Agreement uses first votes. Zeta's first votes were include/include even though Ana changed twice.
    ag = lead.get(f"/reviews/{rid}/agreement").json()["pairs"][0]
    assert ag["n"] == 5 and ag["table"]["include|include"] == 1 and ag["raw_agreement"] == 0.4

    # Export now shows both reviewers for revealed rows only.
    rows = {int(r["publication_id"]): r for r in csv.DictReader(io.StringIO(lead.get(f"/reviews/{rid}/export").text))}
    assert rows[ids["Gamma"]]["first_vote:bruno"] == "exclude" and rows[ids["Gamma"]]["final_decision"] == "include"
    assert rows[ids["Alpha"]]["current_vote:ana"] == "[blinded]"
    ris = lead.get(f"/reviews/{rid}/export", params={"format": "ris"}).text
    assert ris.count("ER  -") == 3 and "Gamma" in ris and "Zeta" in ris and "Theta" in ris

    # Every write was audited, and the audit log never names a vote's decision.
    log = lead.get(f"/reviews/{rid}/audit").json()
    assert {"import", "merge", "assign", "vote", "open_reconciliation", "resolve", "export"} <= {e["action"] for e in log}
    assert all("decision" not in e["detail"] for e in log if e["action"] == "vote")


def test_access_rules(client, users, team_review):
    rid = team_review
    lead, ana, bruno, viewer, outsider = (users[k] for k in ("lead", "ana", "bruno", "viewer", "outsider"))
    ids = setup_votes(users, rid)
    gamma = ids["Gamma"]

    # A non-member cannot even confirm the review exists.
    for path in ("", "/publications", f"/publications/{gamma}", "/screening/ta", "/progress", "/export", "/prisma", "/audit"):
        assert outsider.get(f"/reviews/{rid}{path}").status_code == 404, path
    assert vote(outsider, rid, gamma, "include").status_code == 404

    # Viewer: reads, cannot vote or export.
    assert viewer.get(f"/reviews/{rid}/publications").status_code == 200
    assert vote(viewer, rid, gamma, "include").status_code == 403
    assert viewer.get(f"/reviews/{rid}/export").status_code == 403

    # Reviewer cannot do lead or owner actions.
    forbidden = [
        ("post", f"/reviews/{rid}/assignments", {"stage": "ta", "user_ids": [ana.id]}),
        ("post", f"/reviews/{rid}/stages/ta/reconciliation", None),
        ("post", f"/reviews/{rid}/publications/{gamma}/resolutions", {"stage": "ta", "decision": "include", "note": "x"}),
        ("patch", f"/reviews/{rid}", {"blind_mode": False}),
        ("post", f"/reviews/{rid}/members", {"email": outsider.email, "role": "lead"}),
        ("post", f"/reviews/{rid}/dedup/auto-merge", None),
        ("get", f"/reviews/{rid}/audit", None),
        ("get", f"/reviews/{rid}/agreement", None),
    ]
    for method, path, body in forbidden:
        r = getattr(ana, method)(path, **({"json": body} if body is not None else {}))
        assert r.status_code == 403, (method, path, r.status_code)

    # Lead is not the owner: cannot change blind mode or members.
    lead2_rid = ana.post("/reviews", json={"title": "Ana's own review"}).json()["id"]
    ana.post(f"/reviews/{lead2_rid}/members", json={"email": bruno.email, "role": "lead"})
    assert bruno.patch(f"/reviews/{lead2_rid}", json={"blind_mode": False}).status_code == 403

    # IDs from another review are not found.
    assert ana.get(f"/reviews/{lead2_rid}/publications/{gamma}").status_code == 404
    assert vote(bruno, lead2_rid, gamma, "include").status_code == 404

    # Unassigned publication.
    lead.post(f"/reviews/{rid}/members", json={"email": outsider.email, "role": "reviewer"})
    assert vote(outsider, rid, gamma, "include").status_code == 403

    # Exclusion reason required when the review asks for it.
    lead.patch(f"/reviews/{rid}", json={"require_reason_ta_exclude": True})   # lead is owner here
    r = vote(ana, rid, gamma, "exclude")
    assert r.status_code == 422 and r.json()["error"] == "reason_required"
    reason = lead.post(f"/reviews/{rid}/reasons", json={"stage": "ta", "label": "Wrong population"}).json()["id"]
    assert vote(ana, rid, gamma, "exclude", reason_id=reason).status_code == 201
    other_reason = ana.post(f"/reviews/{lead2_rid}/reasons", json={"stage": "ta", "label": "x"}).json()["id"]
    assert vote(ana, rid, gamma, "exclude", reason_id=other_reason).json()["error"] == "bad_reason"

    # Bad or missing session.
    assert client.get(f"/reviews/{rid}").status_code == 401
    assert client.get(f"/reviews/{rid}", headers={"Authorization": "Bearer forged"}).status_code == 401


def test_turning_blind_mode_off_reveals_and_flags_later_votes(client, users, team_review):
    rid = team_review
    lead, ana, bruno = users["lead"], users["ana"], users["bruno"]
    ids = setup_votes(users, rid)
    vote(bruno, rid, ids["Gamma"], "exclude")
    assert ana.get(f"/reviews/{rid}/publications/{ids['Gamma']}").json()["revealed"] is False
    assert lead.patch(f"/reviews/{rid}", json={"blind_mode": False}).status_code == 200
    g = ana.get(f"/reviews/{rid}/publications/{ids['Gamma']}").json()
    assert g["revealed"] and g["votes"][0]["decision"] == "exclude"
    v = vote(ana, rid, ids["Gamma"], "exclude").json()["vote"]
    assert v["after_reveal"] is True
    assert any(e["action"] == "update" and e["detail"] == {"blind_mode": False} for e in lead.get(f"/reviews/{rid}/audit").json())


def test_history_tables_are_append_only(client, users, team_review):
    rid = team_review
    ids = setup_votes(users, rid)
    vote(users["ana"], rid, ids["Gamma"], "include")
    with psycopg.connect(client.db_url) as c:
        for sql in ("update rp.votes set decision='exclude'", "delete from rp.votes",
                    "update rp.source_records set raw_text=''", "delete from rp.audit_log"):
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                c.execute(sql)
            c.rollback()


def test_full_text_stage(client, users, team_review):
    rid = team_review
    lead, ana, bruno = users["lead"], users["ana"], users["bruno"]
    ids = setup_votes(users, rid)
    for u in (ana, bruno):
        vote(u, rid, ids["Zeta"], "include")
        vote(u, rid, ids["Theta"], "include")
    r = lead.post(f"/reviews/{rid}/assignments", json={"stage": "ft", "user_ids": [ana.id, bruno.id]})
    assert r.json()["assignments_added"] == 4
    assert lead.post(f"/reviews/{rid}/assignments", json={"stage": "ft", "user_ids": [ana.id], "publication_ids": [ids["Gamma"]]}).status_code == 422
    up = lead.post(f"/reviews/{rid}/publications/{ids['Zeta']}/fulltext", files={"file": ("zeta.pdf", b"%PDF-1.4 synthetic")})
    assert up.status_code == 201
    assert ana.get(f"/reviews/{rid}/publications/{ids['Zeta']}/fulltext/{up.json()['id']}").content == b"%PDF-1.4 synthetic"
    lead.post(f"/reviews/{rid}/publications/{ids['Theta']}/retrieval", json={"status": "not_retrieved", "note": "Registry only"})
    assert vote(ana, rid, ids["Theta"], "exclude", stage="ft").json()["error"] == "not_retrieved"
    reason = lead.post(f"/reviews/{rid}/reasons", json={"stage": "ft", "label": "Wrong comparator"}).json()["id"]
    assert vote(ana, rid, ids["Zeta"], "exclude", stage="ft").json()["error"] == "reason_required"
    assert vote(ana, rid, ids["Zeta"], "exclude", stage="ft", reason_id=reason).status_code == 201
    assert lead.get(f"/reviews/{rid}/prisma").json()["ft_not_retrieved"] == 1
