"""Review platform v1 API. See docs/spec/platform-spec.md.

Every response that can carry another reviewer's decision is filtered by the database function
rp.can_see_others(review, publication, stage, user). The web client receives only what it may show.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import pathlib
import secrets
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import Depends, FastAPI, File, Form, Header, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from . import db, dedup
from .parsers import PARSERS, detect_format

app = FastAPI(title="Review platform v1")
app.add_middleware(CORSMiddleware, allow_origins=os.environ.get("WEB_ORIGINS", "http://localhost:3000").split(","),
                   allow_methods=["*"], allow_headers=["*"])

FILES_DIR = pathlib.Path(os.environ.get("FILES_DIR", "./files"))
SESSION_DAYS = 14
Stage = Literal["ta", "ft"]


# ------------------------------------------------------------------ errors
class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        self.status, self.code, self.message = status, code, message


@app.exception_handler(ApiError)
async def api_error(_: Request, exc: ApiError):
    return JSONResponse(status_code=exc.status, content={"error": exc.code, "message": exc.message})


def not_found(what: str = "review"):
    return ApiError(404, "not_found", f"No such {what}, or you are not a member of its review.")


def forbidden(message: str):
    return ApiError(403, "forbidden", message)


# ------------------------------------------------------------------ connection and auth
def get_conn():
    conn = db.connect()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def hash_password(pw: str) -> str:
    salt = secrets.token_bytes(16)
    h = hashlib.scrypt(pw.encode(), salt=salt, n=2 ** 14, r=8, p=1)
    return f"scrypt${salt.hex()}${h.hex()}"


def check_password(pw: str, stored: str) -> bool:
    _, salt, h = stored.split("$")
    return secrets.compare_digest(hashlib.scrypt(pw.encode(), salt=bytes.fromhex(salt), n=2 ** 14, r=8, p=1).hex(), h)


def current_user(authorization: Optional[str] = Header(None), conn=Depends(get_conn)) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise ApiError(401, "unauthenticated", "Sign in first.")
    token = authorization.split(" ", 1)[1].strip()
    row = conn.execute(
        """select u.id, u.email, u.display_name from sessions s join users u on u.id = s.user_id
           where s.token_sha256 = %s and s.expires_at > now()""", (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
    if not row:
        raise ApiError(401, "unauthenticated", "Your session has ended. Sign in again.")
    return row


def audit(conn, review_id, actor, action, entity, entity_id=None, detail=None):
    conn.execute("insert into audit_log(review_id, actor_id, action, entity, entity_id, detail) values (%s,%s,%s,%s,%s,%s)",
                 (review_id, actor, action, entity, entity_id, json.dumps(detail or {})))


def role_in(conn, review_id: int, user: dict) -> str:
    r = conn.execute("select rp.member_role(%s,%s) role", (review_id, user["id"])).fetchone()["role"]
    if r is None:
        raise not_found()
    return r


def need(role: str, allowed: tuple, what: str):
    if role not in allowed:
        raise forbidden(f"Your role ({role}) cannot {what}.")


def publication(conn, review_id: int, pub_id: int) -> dict:
    p = conn.execute("select * from publications where id = %s and review_id = %s", (pub_id, review_id)).fetchone()
    if not p:
        raise not_found("publication")
    return p


# ------------------------------------------------------------------ auth endpoints
class Register(BaseModel):
    email: str
    display_name: str
    password: str = Field(min_length=10)


class Login(BaseModel):
    email: str
    password: str


@app.post("/auth/register", status_code=201)
def register(body: Register, conn=Depends(get_conn)):
    email = body.email.strip().lower()
    if conn.execute("select 1 from users where email = %s", (email,)).fetchone():
        raise ApiError(409, "email_taken", "An account with this e-mail already exists.")
    u = conn.execute("insert into users(email, display_name, password_hash) values (%s,%s,%s) returning id, email, display_name",
                     (email, body.display_name.strip(), hash_password(body.password))).fetchone()
    return u


@app.post("/auth/login")
def login(body: Login, conn=Depends(get_conn)):
    u = conn.execute("select * from users where email = %s", (body.email.strip().lower(),)).fetchone()
    if not u or not check_password(body.password, u["password_hash"]):
        raise ApiError(401, "bad_credentials", "E-mail or password is wrong.")
    token = secrets.token_urlsafe(32)
    conn.execute("insert into sessions(token_sha256, user_id, expires_at) values (%s,%s,%s)",
                 (hashlib.sha256(token.encode()).hexdigest(), u["id"], datetime.now(timezone.utc) + timedelta(days=SESSION_DAYS)))
    return {"token": token, "user": {"id": u["id"], "email": u["email"], "display_name": u["display_name"]}}


@app.post("/auth/logout")
def logout(authorization: Optional[str] = Header(None), conn=Depends(get_conn)):
    if authorization and " " in authorization:
        conn.execute("delete from sessions where token_sha256 = %s",
                     (hashlib.sha256(authorization.split(" ", 1)[1].strip().encode()).hexdigest(),))
    return {"ok": True}


@app.get("/me")
def me(user=Depends(current_user)):
    return user


# ------------------------------------------------------------------ reviews and members
class NewReview(BaseModel):
    title: str
    description: Optional[str] = None


class ReviewPatch(BaseModel):
    blind_mode: Optional[bool] = None
    reviewers_per_publication: Optional[int] = Field(None, ge=1, le=5)
    require_reason_ta_exclude: Optional[bool] = None
    require_reason_ft_exclude: Optional[bool] = None


@app.post("/reviews", status_code=201)
def create_review(body: NewReview, user=Depends(current_user), conn=Depends(get_conn)):
    r = conn.execute("insert into reviews(title, description, created_by) values (%s,%s,%s) returning *",
                     (body.title.strip(), body.description, user["id"])).fetchone()
    conn.execute("insert into members(review_id, user_id, role, added_by) values (%s,%s,'owner',%s)", (r["id"], user["id"], user["id"]))
    audit(conn, r["id"], user["id"], "create", "review", r["id"], {"title": r["title"]})
    return r


@app.get("/reviews")
def list_reviews(user=Depends(current_user), conn=Depends(get_conn)):
    return conn.execute(
        """select r.id, r.title, r.blind_mode, m.role, r.created_at,
                  (select count(*) from publications p where p.review_id = r.id and p.merged_into is null) publications
           from reviews r join members m on m.review_id = r.id and m.user_id = %s and m.removed_at is null order by r.id""",
        (user["id"],)).fetchall()


@app.get("/reviews/{rid}")
def get_review(rid: int, user=Depends(current_user), conn=Depends(get_conn)):
    role = role_in(conn, rid, user)
    r = conn.execute("select * from reviews where id = %s", (rid,)).fetchone()
    members = conn.execute(
        """select u.id, u.display_name, u.email, m.role from members m join users u on u.id = m.user_id
           where m.review_id = %s and m.removed_at is null order by m.added_at""", (rid,)).fetchall()
    stages = conn.execute("select stage, reconciliation_open from stage_state where review_id = %s", (rid,)).fetchall()
    return {**r, "my_role": role, "members": members, "stages": {s["stage"]: s for s in stages}}


@app.patch("/reviews/{rid}")
def patch_review(rid: int, body: ReviewPatch, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner",), "change review settings")
    changes = body.model_dump(exclude_none=True)
    for k, v in changes.items():
        conn.execute(f"update reviews set {k} = %s where id = %s", (v, rid))  # k comes from the model, not the client
    audit(conn, rid, user["id"], "update", "review", rid, changes)
    return conn.execute("select * from reviews where id = %s", (rid,)).fetchone()


class NewMember(BaseModel):
    email: str
    role: Literal["lead", "reviewer", "viewer"]


@app.post("/reviews/{rid}/members", status_code=201)
def add_member(rid: int, body: NewMember, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner",), "add members")
    u = conn.execute("select id, email, display_name from users where email = %s", (body.email.strip().lower(),)).fetchone()
    if not u:
        raise ApiError(404, "no_account", "Nobody has an account with that e-mail yet. Ask them to register first.")
    conn.execute(
        """insert into members(review_id, user_id, role, added_by) values (%s,%s,%s,%s)
           on conflict (review_id, user_id) do update set role = excluded.role, removed_at = null, added_by = excluded.added_by
           where members.role <> 'owner'""", (rid, u["id"], body.role, user["id"]))
    audit(conn, rid, user["id"], "add", "member", u["id"], {"role": body.role})
    return {**u, "role": body.role}


@app.delete("/reviews/{rid}/members/{uid}")
def remove_member(rid: int, uid: int, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner",), "remove members")
    if uid == user["id"]:
        raise ApiError(409, "owner_cannot_leave", "The owner cannot remove themself.")
    conn.execute("update members set removed_at = now() where review_id=%s and user_id=%s and removed_at is null", (rid, uid))
    audit(conn, rid, user["id"], "remove", "member", uid)
    return {"ok": True}


# ------------------------------------------------------------------ import
@app.post("/reviews/{rid}/imports", status_code=201)
async def import_file(rid: int, file: UploadFile = File(...), format: Optional[str] = Form(None),
                      user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "import references")
    fmt = format or detect_format(file.filename or "")
    if fmt not in PARSERS:
        raise ApiError(422, "unknown_format", "Use a .ris, .bib or .csv file, or say which format it is.")
    data = await file.read()
    sha = hashlib.sha256(data).hexdigest()
    dup = conn.execute("select id, filename from import_batches where review_id=%s and file_sha256=%s", (rid, sha)).fetchone()
    if dup:
        raise ApiError(409, "already_imported", f"This exact file was already imported as '{dup['filename']}' (batch {dup['id']}).")
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    entries, failures = PARSERS[fmt](text)
    n_warn = sum(1 for e in entries if e["warnings"])
    b = conn.execute(
        """insert into import_batches(review_id, filename, format, file_sha256, file_bytes, uploaded_by, n_entries, n_ok, n_warnings, n_failed)
           values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
        (rid, file.filename, fmt, sha, data, user["id"], len(entries) + len(failures), len(entries), n_warn, len(failures))).fetchone()
    for i, e in enumerate(entries, 1):
        sr = conn.execute(
            "insert into source_records(review_id, batch_id, ordinal, raw_text, fields, warnings) values (%s,%s,%s,%s,%s,%s) returning id",
            (rid, b["id"], i, e["raw_text"], json.dumps(e["fields"]), e["warnings"])).fetchone()
        n = e["norm"]
        p = conn.execute(
            """insert into publications(review_id, title, abstract, year, doi_norm, pmid, journal, authors, kind)
               values (%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
            (rid, n["title"], n["abstract"], n["year"], n["doi_norm"], n["pmid"], n["journal"], n["authors"], n["kind"])).fetchone()
        conn.execute("insert into publication_sources(review_id, publication_id, source_record_id, linked_by, link_reason) values (%s,%s,%s,%s,'import')",
                     (rid, p["id"], sr["id"], user["id"]))
    summary = {"batch_id": b["id"], "filename": file.filename, "format": fmt, "entries_found": len(entries) + len(failures),
               "imported": len(entries), "with_warnings": n_warn, "failed": len(failures), "failures": failures}
    audit(conn, rid, user["id"], "import", "import_batch", b["id"], {k: v for k, v in summary.items() if k != "failures"})
    return summary


@app.get("/reviews/{rid}/imports")
def list_imports(rid: int, user=Depends(current_user), conn=Depends(get_conn)):
    role_in(conn, rid, user)
    return conn.execute(
        """select id, filename, format, file_sha256, uploaded_at, n_entries, n_ok, n_warnings, n_failed
           from import_batches where review_id=%s order by id""", (rid,)).fetchall()


@app.get("/reviews/{rid}/publications")
def list_publications(rid: int, include_merged: bool = False, user=Depends(current_user), conn=Depends(get_conn)):
    role_in(conn, rid, user)
    return conn.execute(
        f"""select p.id, p.title, p.year, p.doi_norm, p.pmid, p.kind, p.merged_into,
                   (select array_agg(ps.source_record_id order by ps.source_record_id) from publication_sources ps
                     where ps.publication_id = p.id and ps.unlinked_at is null) source_records,
                   (select sp.study_id from study_publications sp where sp.publication_id = p.id and sp.unlinked_at is null) study_id
            from publications p where p.review_id = %s {'' if include_merged else 'and p.merged_into is null'} order by p.id""",
        (rid,)).fetchall()


# ------------------------------------------------------------------ duplicates
@app.post("/reviews/{rid}/dedup/detect")
def dedup_detect(rid: int, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "detect duplicates")
    out = dedup.detect(conn, rid)
    audit(conn, rid, user["id"], "detect", "dedup", None, out)
    return out


@app.get("/reviews/{rid}/dedup/candidates")
def dedup_candidates(rid: int, status: Optional[str] = None, user=Depends(current_user), conn=Depends(get_conn)):
    role_in(conn, rid, user)
    q = """select c.*, pa.title title_a, pb.title title_b, pa.year year_a, pb.year year_b
           from dedup_candidates c join publications pa on pa.id = c.publication_a join publications pb on pb.id = c.publication_b
           where c.review_id = %s"""
    args: list = [rid]
    if status:
        q += " and c.status = %s"
        args.append(status)
    return conn.execute(q + " order by c.id", args).fetchall()


def _candidate(conn, rid, cid):
    c = conn.execute("select * from dedup_candidates where id=%s and review_id=%s", (cid, rid)).fetchone()
    if not c:
        raise not_found("duplicate candidate")
    return c


def _do_merge(conn, rid, c, user, force=False):
    a, b = dedup.root_of(conn, c["publication_a"]), dedup.root_of(conn, c["publication_b"])
    if a == b:
        conn.execute("update dedup_candidates set status='merged', decided_by=%s, decided_at=now() where id=%s", (user["id"], c["id"]))
        return {"kept": a, "merged": None, "note": "already in the same publication"}
    keep, drop = min(a, b), max(a, b)
    if not force and conn.execute("select 1 from votes where publication_id in (%s,%s)", (keep, drop)).fetchone():
        raise ApiError(409, "has_votes", "One of these publications already has votes. Merge with force=true if you are sure.")
    out = dedup.merge(conn, rid, keep, drop, user["id"])
    conn.execute("update dedup_candidates set status='merged', decided_by=%s, decided_at=now() where id=%s", (user["id"], c["id"]))
    audit(conn, rid, user["id"], "merge", "publication", keep, {**out, "candidate": c["id"], "rule": c["rule"]})
    return out


@app.post("/reviews/{rid}/dedup/candidates/{cid}/merge")
def dedup_merge(rid: int, cid: int, force: bool = False, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "merge duplicates")
    c = _candidate(conn, rid, cid)
    if c["status"] != "open":
        raise ApiError(409, "already_decided", f"This candidate is already {c['status']}.")
    return _do_merge(conn, rid, c, user, force)


@app.post("/reviews/{rid}/dedup/candidates/{cid}/reject")
def dedup_reject(rid: int, cid: int, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "decide duplicates")
    c = _candidate(conn, rid, cid)
    conn.execute("update dedup_candidates set status='rejected', decided_by=%s, decided_at=now() where id=%s", (user["id"], cid))
    audit(conn, rid, user["id"], "reject", "dedup_candidate", cid, {"previous": c["status"]})
    return {"ok": True}


@app.post("/reviews/{rid}/dedup/auto-merge")
def dedup_auto(rid: int, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "merge duplicates")
    rows = conn.execute("""select * from dedup_candidates where review_id=%s and status='open' and score >= 1.0
                           and cardinality(blockers) = 0 order by id""", (rid,)).fetchall()
    done, skipped = [], []
    for c in rows:
        try:
            done.append({"candidate": c["id"], **_do_merge(conn, rid, c, user)})
        except ApiError as e:
            skipped.append({"candidate": c["id"], "reason": e.code})
    return {"merged": done, "skipped": skipped}


class Split(BaseModel):
    source_record_id: int


@app.post("/reviews/{rid}/publications/{pid}/split")
def split(rid: int, pid: int, body: Split, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "split publications")
    publication(conn, rid, pid)
    out = dedup.split(conn, rid, pid, body.source_record_id, user["id"])
    if "error" in out:
        msg = {"not_linked": "That source record is not part of this publication.",
               "last_source": "This is the publication's only source record; there is nothing to split."}[out["error"]]
        raise ApiError(409, out["error"], msg)
    audit(conn, rid, user["id"], "split", "publication", pid, out)
    return out


# ------------------------------------------------------------------ studies
class NewStudy(BaseModel):
    label: str
    primary_publication_id: int
    secondary_publication_ids: list[int] = []


@app.post("/reviews/{rid}/studies", status_code=201)
def create_study(rid: int, body: NewStudy, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "manage studies")
    s = conn.execute("insert into studies(review_id, label, created_by) values (%s,%s,%s) returning *", (rid, body.label, user["id"])).fetchone()
    for pid, role in [(body.primary_publication_id, "primary")] + [(x, "secondary") for x in body.secondary_publication_ids]:
        _link_study(conn, rid, s["id"], pid, role, user)
    audit(conn, rid, user["id"], "create", "study", s["id"], body.model_dump())
    return s


def _link_study(conn, rid, sid, pid, role, user):
    p = publication(conn, rid, pid)
    if p["merged_into"]:
        raise ApiError(409, "publication_merged", f"Publication {pid} was merged into {p['merged_into']}; link that one.")
    conn.execute("update study_publications set unlinked_at=now(), unlinked_by=%s where publication_id=%s and unlinked_at is null", (user["id"], pid))
    conn.execute("insert into study_publications(review_id, study_id, publication_id, role, linked_by) values (%s,%s,%s,%s,%s)",
                 (rid, sid, pid, role, user["id"]))


class StudyLink(BaseModel):
    publication_id: int
    role: Literal["primary", "secondary"] = "secondary"


@app.post("/reviews/{rid}/studies/{sid}/publications")
def link_study(rid: int, sid: int, body: StudyLink, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "manage studies")
    if not conn.execute("select 1 from studies where id=%s and review_id=%s", (sid, rid)).fetchone():
        raise not_found("study")
    _link_study(conn, rid, sid, body.publication_id, body.role, user)
    audit(conn, rid, user["id"], "link", "study", sid, body.model_dump())
    return {"ok": True}


@app.get("/reviews/{rid}/studies")
def list_studies(rid: int, user=Depends(current_user), conn=Depends(get_conn)):
    role_in(conn, rid, user)
    return conn.execute(
        """select s.id, s.label, json_agg(json_build_object('publication_id', sp.publication_id, 'role', sp.role) order by sp.publication_id) publications
           from studies s join study_publications sp on sp.study_id = s.id and sp.unlinked_at is null
           where s.review_id = %s group by s.id order by s.id""", (rid,)).fetchall()


# ------------------------------------------------------------------ reasons and assignments
class NewReason(BaseModel):
    stage: Literal["ta", "ft", "both"]
    label: str


@app.post("/reviews/{rid}/reasons", status_code=201)
def add_reason(rid: int, body: NewReason, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "edit exclusion reasons")
    r = conn.execute("insert into reason_labels(review_id, stage, label) values (%s,%s,%s) returning *", (rid, body.stage, body.label)).fetchone()
    audit(conn, rid, user["id"], "create", "reason_label", r["id"], body.model_dump())
    return r


@app.get("/reviews/{rid}/reasons")
def list_reasons(rid: int, user=Depends(current_user), conn=Depends(get_conn)):
    role_in(conn, rid, user)
    return conn.execute("select * from reason_labels where review_id=%s and active order by id", (rid,)).fetchall()


class Assign(BaseModel):
    stage: Stage
    user_ids: list[int]
    publication_ids: Optional[list[int]] = None   # default: every eligible publication


def eligible_ids(conn, rid: int, stage: str) -> list[int]:
    if stage == "ta":
        q = "select id from publications where review_id=%s and merged_into is null order by id"
    else:
        q = "select id from publications where review_id=%s and merged_into is null and rp.final_decision(review_id, id, 'ta') = 'include' order by id"
    return [r["id"] for r in conn.execute(q, (rid,)).fetchall()]


@app.post("/reviews/{rid}/assignments")
def assign(rid: int, body: Assign, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "assign publications")
    rv = conn.execute("select * from reviews where id=%s", (rid,)).fetchone()
    for uid in body.user_ids:
        r = conn.execute("select rp.member_role(%s,%s) role", (rid, uid)).fetchone()["role"]
        if r not in ("owner", "lead", "reviewer"):
            raise ApiError(422, "not_a_screener", f"User {uid} is not a member who can screen.")
    eligible = set(eligible_ids(conn, rid, body.stage))
    targets = body.publication_ids if body.publication_ids is not None else sorted(eligible)
    bad = [p for p in targets if p not in eligible]
    if bad:
        raise ApiError(422, "not_eligible", f"Not eligible for this stage (merged, from another review, or not included at title/abstract): {bad}")
    added, full = 0, []
    for pid in targets:
        have = {r["user_id"] for r in conn.execute("select user_id from assignments where review_id=%s and stage=%s and publication_id=%s",
                                                    (rid, body.stage, pid)).fetchall()}
        want = [u for u in body.user_ids if u not in have]
        if len(have) + len(want) > rv["reviewers_per_publication"]:
            full.append(pid)
            continue
        for uid in want:
            conn.execute("insert into assignments(review_id, stage, publication_id, user_id, assigned_by) values (%s,%s,%s,%s,%s)",
                         (rid, body.stage, pid, uid, user["id"]))
            added += 1
    audit(conn, rid, user["id"], "assign", "assignments", None, {"stage": body.stage, "users": body.user_ids, "added": added, "skipped_full": full})
    return {"assignments_added": added, "publications_skipped_already_full": full}


# ------------------------------------------------------------------ blinded views
def vote_public(v: dict) -> dict:
    return {k: v[k] for k in ("id", "user_id", "decision", "reason_id", "note", "created_at", "supersedes_id", "after_reveal")}


def pub_view(conn, rid: int, p: dict, stage: str, user: dict) -> dict:
    """What `user` may know about publication `p` at `stage`."""
    see = conn.execute("select rp.can_see_others(%s,%s,%s,%s) v", (rid, p["id"], stage, user["id"])).fetchone()["v"]
    mine = conn.execute("select * from votes where review_id=%s and publication_id=%s and stage=%s and user_id=%s order by id",
                        (rid, p["id"], stage, user["id"])).fetchall()
    out = {
        "publication": {k: p[k] for k in ("id", "title", "abstract", "year", "doi_norm", "pmid", "journal", "authors", "kind", "merged_into")},
        "stage": stage,
        "assigned_to_me": conn.execute("select rp.is_assigned(%s,%s,%s,%s) v", (rid, p["id"], stage, user["id"])).fetchone()["v"],
        "my_vote": vote_public(mine[-1]) if mine else None,
        "my_vote_changes": max(len(mine) - 1, 0),
        "revealed": see,
        "locked": conn.execute("select rp.votes_locked(%s,%s,%s) v", (rid, p["id"], stage)).fetchone()["v"],
    }
    if see:
        st = conn.execute("select * from rp.pub_status(%s,%s,%s)", (rid, p["id"], stage)).fetchone()
        res = conn.execute("select * from current_resolutions where review_id=%s and publication_id=%s and stage=%s",
                           (rid, p["id"], stage)).fetchone()
        others = conn.execute(
            """select cv.*, u.display_name, (select f.decision from first_votes f where f.review_id=cv.review_id and f.stage=cv.stage
                        and f.publication_id=cv.publication_id and f.user_id=cv.user_id) first_decision
               from current_votes cv join users u on u.id = cv.user_id
               where cv.review_id=%s and cv.publication_id=%s and cv.stage=%s order by cv.user_id""", (rid, p["id"], stage)).fetchall()
        out.update(status=st["status"], uncertain=st["uncertain"],
                   final_decision=conn.execute("select rp.final_decision(%s,%s,%s) v", (rid, p["id"], stage)).fetchone()["v"],
                   votes=[{**vote_public(v), "display_name": v["display_name"], "first_decision": v["first_decision"]} for v in others],
                   resolution=res and {k: res[k] for k in ("id", "decision", "reason_id", "note", "resolved_by", "created_at")})
    else:
        out["status"] = "voted" if mine else "pending"
    return out


@app.get("/reviews/{rid}/publications/{pid}")
def get_publication(rid: int, pid: int, stage: Stage = "ta", user=Depends(current_user), conn=Depends(get_conn)):
    role_in(conn, rid, user)
    p = publication(conn, rid, pid)
    view = pub_view(conn, rid, p, stage, user)
    view["source_records"] = conn.execute(
        """select sr.id, b.filename, sr.ordinal, sr.raw_text, sr.warnings from publication_sources ps
           join source_records sr on sr.id = ps.source_record_id join import_batches b on b.id = sr.batch_id
           where ps.publication_id=%s and ps.unlinked_at is null order by sr.id""", (pid,)).fetchall()
    return view


@app.get("/reviews/{rid}/screening/{stage}")
def my_queue(rid: int, stage: Stage, only_pending: bool = False, user=Depends(current_user), conn=Depends(get_conn)):
    role = role_in(conn, rid, user)
    assigned = conn.execute("select rp.is_assigned_in_stage(%s,%s,%s) v", (rid, stage, user["id"])).fetchone()["v"]
    if assigned:
        ids = [r["publication_id"] for r in conn.execute(
            "select publication_id from assignments where review_id=%s and stage=%s and user_id=%s order by publication_id",
            (rid, stage, user["id"])).fetchall()]
    else:
        ids = eligible_ids(conn, rid, stage)
    items = []
    for pid in ids:
        v = pub_view(conn, rid, publication(conn, rid, pid), stage, user)
        if only_pending and v["my_vote"]:
            continue
        items.append(v)
    return {"role": role, "assigned_to_me": assigned, "items": items}


@app.get("/reviews/{rid}/progress")
def progress(rid: int, stage: Stage = "ta", user=Depends(current_user), conn=Depends(get_conn)):
    """Own counts always; team split only over publications revealed to this user (spec §7)."""
    role = role_in(conn, rid, user)
    mine = conn.execute(
        """select coalesce(cv.decision, 'pending') d, count(*) n from assignments a
           left join current_votes cv on cv.review_id=a.review_id and cv.stage=a.stage and cv.publication_id=a.publication_id and cv.user_id=a.user_id
           where a.review_id=%s and a.stage=%s and a.user_id=%s group by 1""", (rid, stage, user["id"])).fetchall()
    team: dict[str, int] = {}
    hidden = 0
    for pid in eligible_ids(conn, rid, stage):
        if conn.execute("select rp.can_see_others(%s,%s,%s,%s) v", (rid, pid, stage, user["id"])).fetchone()["v"]:
            s = conn.execute("select status from rp.pub_status(%s,%s,%s)", (rid, pid, stage)).fetchone()["status"]
            if s in ("included", "excluded") or conn.execute(
                    "select 1 from current_resolutions where review_id=%s and publication_id=%s and stage=%s", (rid, pid, stage)).fetchone():
                s = {"include": "included", "exclude": "excluded"}[conn.execute("select rp.final_decision(%s,%s,%s) v", (rid, pid, stage)).fetchone()["v"]]
            team[s] = team.get(s, 0) + 1
        else:
            hidden += 1
    out = {"stage": stage, "mine": {r["d"]: r["n"] for r in mine}, "team_revealed": team, "team_not_revealed": hidden}
    if role in ("owner", "lead") and not conn.execute("select rp.is_assigned_in_stage(%s,%s,%s) v", (rid, stage, user["id"])).fetchone()["v"]:
        out["per_reviewer_votes_cast"] = conn.execute(
            """select a.user_id, count(*) assigned, count(cv.id) voted from assignments a
               left join current_votes cv on cv.review_id=a.review_id and cv.stage=a.stage and cv.publication_id=a.publication_id and cv.user_id=a.user_id
               where a.review_id=%s and a.stage=%s group by a.user_id order by a.user_id""", (rid, stage)).fetchall()
    return out


# ------------------------------------------------------------------ voting
class NewVote(BaseModel):
    stage: Stage
    decision: Literal["include", "exclude", "maybe"]
    reason_id: Optional[int] = None
    note: Optional[str] = None


@app.post("/reviews/{rid}/publications/{pid}/votes", status_code=201)
def vote(rid: int, pid: int, body: NewVote, user=Depends(current_user), conn=Depends(get_conn)):
    role = role_in(conn, rid, user)
    need(role, ("owner", "lead", "reviewer"), "vote")
    p = publication(conn, rid, pid)
    if p["merged_into"]:
        raise ApiError(409, "publication_merged", f"This publication was merged into {p['merged_into']}. Screen that one.")
    if not conn.execute("select rp.is_assigned(%s,%s,%s,%s) v", (rid, pid, body.stage, user["id"])).fetchone()["v"]:
        raise forbidden("This publication is not assigned to you at this stage.")
    if body.stage == "ft":
        r = conn.execute("select status from retrieval where review_id=%s and publication_id=%s", (rid, pid)).fetchone()
        if r and r["status"] == "not_retrieved":
            raise ApiError(409, "not_retrieved", "The full text is marked as not retrieved. That is not an exclusion; it cannot be screened.")
    if conn.execute("select rp.votes_locked(%s,%s,%s) v", (rid, pid, body.stage)).fetchone()["v"]:
        raise ApiError(409, "votes_locked", "Votes on this publication are locked because reconciliation is open. A lead resolves it.")
    rv = conn.execute("select * from reviews where id=%s", (rid,)).fetchone()
    if body.decision == "exclude" and body.reason_id is None and rv[f"require_reason_{body.stage}_exclude"]:
        raise ApiError(422, "reason_required", "Choose a reason for excluding at this stage.")
    if body.reason_id is not None and not conn.execute(
            "select 1 from reason_labels where id=%s and review_id=%s and active and stage in (%s,'both')", (body.reason_id, rid, body.stage)).fetchone():
        raise ApiError(422, "bad_reason", "That reason does not exist for this review and stage.")
    prev = conn.execute("select id from votes where review_id=%s and publication_id=%s and stage=%s and user_id=%s order by id desc limit 1",
                        (rid, pid, body.stage, user["id"])).fetchone()
    v = conn.execute(
        """insert into votes(review_id, stage, publication_id, user_id, decision, reason_id, note, supersedes_id, after_reveal)
           values (%s,%s,%s,%s,%s,%s,%s,%s,%s) returning *""",
        (rid, body.stage, pid, user["id"], body.decision, body.reason_id, body.note, prev and prev["id"], not rv["blind_mode"])).fetchone()
    # The audit entry names the vote but not the decision, so the audit log cannot unblind anyone.
    audit(conn, rid, user["id"], "vote", "publication", pid, {"stage": body.stage, "vote_id": v["id"], "changed": prev is not None})
    return {"vote": vote_public(v), "changed_previous": prev is not None}


# ------------------------------------------------------------------ reconciliation and resolution
@app.post("/reviews/{rid}/stages/{stage}/reconciliation")
def open_reconciliation(rid: int, stage: Stage, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "open reconciliation")
    conn.execute("""insert into stage_state(review_id, stage, reconciliation_open, opened_by, opened_at) values (%s,%s,true,%s,now())
                    on conflict (review_id, stage) do update set reconciliation_open=true, opened_by=excluded.opened_by, opened_at=now()""",
                 (rid, stage, user["id"]))
    ids = eligible_ids(conn, rid, stage)
    revealed = sum(conn.execute("select rp.all_voted(%s,%s,%s) v", (rid, p, stage)).fetchone()["v"] for p in ids)
    out = {"stage": stage, "revealed_now": revealed, "still_blind_pending_votes": len(ids) - revealed}
    audit(conn, rid, user["id"], "open_reconciliation", "stage", None, out)
    return out


@app.get("/reviews/{rid}/stages/{stage}/conflicts")
def conflicts(rid: int, stage: Stage, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "see conflicts")
    out = []
    for pid in eligible_ids(conn, rid, stage):
        if not conn.execute("select rp.can_see_others(%s,%s,%s,%s) v", (rid, pid, stage, user["id"])).fetchone()["v"]:
            continue
        if conn.execute("select status from rp.pub_status(%s,%s,%s)", (rid, pid, stage)).fetchone()["status"] == "conflict":
            out.append(pub_view(conn, rid, publication(conn, rid, pid), stage, user))
    return out


class NewResolution(BaseModel):
    stage: Stage
    decision: Literal["include", "exclude"]
    reason_id: Optional[int] = None
    note: str = Field(min_length=1)


@app.post("/reviews/{rid}/publications/{pid}/resolutions", status_code=201)
def resolve(rid: int, pid: int, body: NewResolution, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "resolve conflicts")
    publication(conn, rid, pid)
    if not conn.execute("select rp.can_see_others(%s,%s,%s,%s) v", (rid, pid, body.stage, user["id"])).fetchone()["v"]:
        raise ApiError(409, "not_revealed", "Open reconciliation and wait for all assigned votes before resolving.")
    st = conn.execute("select status from rp.pub_status(%s,%s,%s)", (rid, pid, body.stage)).fetchone()["status"]
    if st != "conflict":
        raise ApiError(409, "no_conflict", f"This publication is '{st}', not in conflict.")
    if body.decision == "exclude" and body.stage == "ft" and body.reason_id is None:
        raise ApiError(422, "reason_required", "A full-text exclusion needs a reason.")
    prev = conn.execute("select id from current_resolutions where review_id=%s and publication_id=%s and stage=%s", (rid, pid, body.stage)).fetchone()
    r = conn.execute(
        """insert into resolutions(review_id, stage, publication_id, decision, reason_id, note, resolved_by, supersedes_id)
           values (%s,%s,%s,%s,%s,%s,%s,%s) returning *""",
        (rid, body.stage, pid, body.decision, body.reason_id, body.note, user["id"], prev and prev["id"])).fetchone()
    audit(conn, rid, user["id"], "resolve", "publication", pid, {"stage": body.stage, "resolution_id": r["id"], "decision": body.decision})
    return r


# ------------------------------------------------------------------ full text
@app.post("/reviews/{rid}/publications/{pid}/fulltext", status_code=201)
async def upload_fulltext(rid: int, pid: int, file: UploadFile = File(...), user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "upload full texts")
    publication(conn, rid, pid)
    data = await file.read()
    sha = hashlib.sha256(data).hexdigest()
    FILES_DIR.mkdir(parents=True, exist_ok=True)
    (FILES_DIR / sha).write_bytes(data)
    f = conn.execute("""insert into fulltext_files(review_id, publication_id, sha256, filename, bytes, uploaded_by)
                        values (%s,%s,%s,%s,%s,%s) returning id, sha256, filename, bytes""",
                     (rid, pid, sha, file.filename, len(data), user["id"])).fetchone()
    _set_retrieval(conn, rid, pid, "retrieved", None, user)
    audit(conn, rid, user["id"], "upload", "fulltext", f["id"], {"publication_id": pid, "sha256": sha, "bytes": len(data)})
    return f


@app.get("/reviews/{rid}/publications/{pid}/fulltext/{fid}")
def download_fulltext(rid: int, pid: int, fid: int, user=Depends(current_user), conn=Depends(get_conn)):
    role_in(conn, rid, user)
    f = conn.execute("select * from fulltext_files where id=%s and publication_id=%s and review_id=%s", (fid, pid, rid)).fetchone()
    if not f:
        raise not_found("file")
    return Response((FILES_DIR / f["sha256"]).read_bytes(), media_type="application/pdf",
                    headers={"Content-Disposition": f'attachment; filename="{f["filename"]}"'})


class Retrieval(BaseModel):
    status: Literal["pending", "retrieved", "not_retrieved"]
    note: Optional[str] = None


def _set_retrieval(conn, rid, pid, status, note, user):
    conn.execute("""insert into retrieval(review_id, publication_id, status, note, updated_by) values (%s,%s,%s,%s,%s)
                    on conflict (review_id, publication_id) do update set status=excluded.status, note=excluded.note,
                    updated_by=excluded.updated_by, updated_at=now()""", (rid, pid, status, note, user["id"]))


@app.post("/reviews/{rid}/publications/{pid}/retrieval")
def set_retrieval(rid: int, pid: int, body: Retrieval, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "record retrieval")
    publication(conn, rid, pid)
    _set_retrieval(conn, rid, pid, body.status, body.note, user)
    audit(conn, rid, user["id"], "retrieval", "publication", pid, body.model_dump())
    return {"ok": True}


# ------------------------------------------------------------------ export, PRISMA, audit
@app.get("/reviews/{rid}/export")
def export(rid: int, stage: Stage = "ta", format: Literal["csv", "ris"] = "csv", user=Depends(current_user), conn=Depends(get_conn)):
    role = role_in(conn, rid, user)
    need(role, ("owner", "lead", "reviewer"), "export")
    members = conn.execute("""select u.id, u.display_name from members m join users u on u.id=m.user_id
                              where m.review_id=%s and m.role <> 'viewer' order by u.id""", (rid,)).fetchall()
    rows = []
    for pid in eligible_ids(conn, rid, stage):
        p = publication(conn, rid, pid)
        v = pub_view(conn, rid, p, stage, user)
        files = [r["filename"] for r in conn.execute(
            """select distinct b.filename from publication_sources ps join source_records sr on sr.id=ps.source_record_id
               join import_batches b on b.id=sr.batch_id where ps.publication_id=%s and ps.unlinked_at is null order by 1""", (pid,)).fetchall()]
        row = {"publication_id": pid, "title": p["title"], "year": p["year"], "doi": p["doi_norm"], "pmid": p["pmid"],
               "kind": p["kind"], "source_files": "; ".join(files), "status": v["status"],
               "final_decision": v.get("final_decision") or "", "resolution_note": (v.get("resolution") or {}).get("note", "")}
        by_user = {x["user_id"]: x for x in v.get("votes", [])}
        for m in members:
            if v["revealed"]:
                x = by_user.get(m["id"])
                row[f"first_vote:{m['display_name']}"] = x["first_decision"] if x else ""
                row[f"current_vote:{m['display_name']}"] = x["decision"] if x else ""
            elif m["id"] == user["id"]:
                row[f"current_vote:{m['display_name']}"] = v["my_vote"]["decision"] if v["my_vote"] else ""
            else:
                row[f"current_vote:{m['display_name']}"] = "[blinded]"
        rows.append(row)
    audit(conn, rid, user["id"], "export", "review", rid, {"stage": stage, "format": format, "rows": len(rows)})
    if format == "ris":
        included = [r for r in rows if r["final_decision"] == "include"]
        out = []
        for r in included:
            p = publication(conn, rid, r["publication_id"])
            out += ["TY  - " + {"conference": "CONF", "registry": "DBASE"}.get(p["kind"], "JOUR"), f"TI  - {p['title'] or ''}"]
            out += [f"AU  - {a}" for a in p["authors"]]
            out += [f"PY  - {p['year'] or ''}", f"T2  - {p['journal'] or ''}"]
            out += [f"DO  - {p['doi_norm']}"] if p["doi_norm"] else []
            out += [f"AN  - {p['pmid']}"] if p["pmid"] else []
            out += [f"AB  - {p['abstract'] or ''}", f"N1  - review publication {p['id']}", "ER  -", ""]
        return Response("\n".join(out), media_type="application/x-research-info-systems",
                        headers={"Content-Disposition": f'attachment; filename="review-{rid}-{stage}-included.ris"'})
    buf = io.StringIO()
    if rows:
        cols = list(dict.fromkeys(k for r in rows for k in r))
        w = csv.DictWriter(buf, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    return Response(buf.getvalue(), media_type="text/csv",
                    headers={"Content-Disposition": f'attachment; filename="review-{rid}-{stage}.csv"'})


@app.get("/reviews/{rid}/prisma")
def prisma(rid: int, user=Depends(current_user), conn=Depends(get_conn)):
    role_in(conn, rid, user)
    q1 = lambda sql: conn.execute(sql, (rid,)).fetchone()["n"]  # noqa: E731
    out = {
        "records_identified_by_file": conn.execute(
            "select filename, n_ok records from import_batches where review_id=%s order by id", (rid,)).fetchall(),
        "records_identified": q1("select count(*) n from source_records where review_id=%s"),
        "publications_after_duplicates": q1("select count(*) n from publications where review_id=%s and merged_into is null"),
    }
    out["duplicates_removed"] = out["records_identified"] - out["publications_after_duplicates"]
    for stage in ("ta", "ft"):
        pr = progress(rid, stage, user, conn)
        out[stage] = pr["team_revealed"] | {"not_revealed": pr["team_not_revealed"]}
    out["ft_not_retrieved"] = q1("select count(*) n from retrieval where review_id=%s and status='not_retrieved'")
    out["studies"] = q1("select count(*) n from studies where review_id=%s")
    return out


@app.get("/reviews/{rid}/agreement")
def agreement(rid: int, stage: Stage = "ta", user=Depends(current_user), conn=Depends(get_conn)):
    """Raw agreement and Cohen's kappa between each pair of reviewers, from their FIRST votes,
    over publications revealed to the requester. Resolutions do not enter this calculation."""
    need(role_in(conn, rid, user), ("owner", "lead"), "see agreement statistics")
    pairs: dict[tuple[int, int], list[tuple[str, str]]] = {}
    for pid in eligible_ids(conn, rid, stage):
        if not conn.execute("select rp.can_see_others(%s,%s,%s,%s) v", (rid, pid, stage, user["id"])).fetchone()["v"]:
            continue
        fv = conn.execute("""select f.user_id, f.decision from first_votes f join assignments a on a.review_id=f.review_id
                             and a.stage=f.stage and a.publication_id=f.publication_id and a.user_id=f.user_id
                             where f.review_id=%s and f.publication_id=%s and f.stage=%s order by f.user_id""", (rid, pid, stage)).fetchall()
        for i in range(len(fv)):
            for j in range(i + 1, len(fv)):
                pairs.setdefault((fv[i]["user_id"], fv[j]["user_id"]), []).append((fv[i]["decision"], fv[j]["decision"]))
    out = []
    cats = ("include", "maybe", "exclude")
    for (a, b), obs in pairs.items():
        n = len(obs)
        po = sum(x == y for x, y in obs) / n
        pe = sum((sum(x == c for x, _ in obs) / n) * (sum(y == c for _, y in obs) / n) for c in cats)
        kappa = None if pe == 1 else (po - pe) / (1 - pe)
        out.append({"reviewer_a": a, "reviewer_b": b, "n": n, "raw_agreement": round(po, 4),
                    "cohen_kappa": None if kappa is None else round(kappa, 4),
                    "table": {f"{c1}|{c2}": sum(1 for x, y in obs if x == c1 and y == c2) for c1 in cats for c2 in cats}})
    return {"stage": stage, "basis": "first independent votes", "pairs": out}


@app.get("/reviews/{rid}/audit")
def audit_log(rid: int, user=Depends(current_user), conn=Depends(get_conn)):
    need(role_in(conn, rid, user), ("owner", "lead"), "read the audit log")
    return conn.execute("""select a.id, a.created_at, u.display_name actor, a.action, a.entity, a.entity_id, a.detail
                           from audit_log a left join users u on u.id=a.actor_id where a.review_id=%s order by a.id""", (rid,)).fetchall()


@app.get("/health")
def health(conn=Depends(get_conn)):
    conn.execute("select 1")
    return {"ok": True}
