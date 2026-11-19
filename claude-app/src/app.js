/* FishingMeta — runs inside a claude.ai artifact.
 *
 * Blinding model (enforced by the artifact database's rules, not by this code):
 *   data/users/<me>/...   my votes and my AI suggestions; nobody else can read them, the owner included
 *   progress/<me>         how many of my assignments I have voted on (counts only, no decisions)
 *   released/<me>/r/...   my votes, copied here by my own page once the lead opens reconciliation;
 *                         readable by the team, writable only by me
 *   everything else       shared review data; only Editors (admin) and the owner write it
 * Opening reconciliation closes voting for that stage.
 */
"use strict";

const CHUNK = 60;              // publications per stored document
const STAGES = { ta: "Title and abstract", ft: "Full text" };
const DEC = ["include", "maybe", "exclude"];

const S = {
  db: null, user: null, uid: null, canEdit: false, isOwner: false, sample: null, downloads: null,
  names: {}, reviews: [], rid: null, review: null,
  pubs: {}, imports: [], members: {}, dedup: { candidates: [], log: [] }, assign: { ta: {}, ft: {} },
  stages: {}, resolutions: {}, retrieval: {}, myVotes: {}, myAi: {}, progress: {}, released: {},
  tab: "overview", stage: "ta", sel: null, filter: "todo", unsub: [], relUnsub: [], msg: "",
  ready: { mine: false, assign: {}, stages: {} },
  assets: null, fulltext: {}, setup: { outcomes: [], studyFields: ["Design", "Country", "Follow-up"], arms: ["Intervention", "Control"] },
  extraction: {}, analysis: [], requests: {}, manuscript: null, xsel: null, aiDraft: null, claudeVotes: {},
};

// ---------------------------------------------------------------- small helpers
const $ = (sel, root = document) => root.querySelector(sel);
const h = (tag, attrs = {}, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === false || v == null) continue;
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "html") el.innerHTML = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  return el;
};
const nowIso = () => new Date().toISOString();
const pad = (n, w = 4) => String(n).padStart(w, "0");
const chunkOf = (pid) => Math.floor(Number(pid.slice(1)) / CHUNK);
const CLAUDE = "claude";   // Claude reviews as its own member; its votes are kept blind in the owner's private area
const nameOf = (uid) => (uid === CLAUDE ? "Claude (AI)" : uid === S.uid ? "You" : (S.names[uid] || "Team member"));
const fullName = (uid) => (uid === CLAUDE ? "Claude (AI)" : S.names[uid] || "Team member " + String(uid).slice(-4));
const say = (text, isErr) => { S.msg = { text, isErr }; renderMsg(); };

// One write at a time per document (platform rule).
const writeChains = new Map();
function serialWrite(path, fn) {
  const prev = writeChains.get(path) || Promise.resolve();
  const next = prev.catch(() => {}).then(fn);
  writeChains.set(path, next);
  return next;
}
async function sha256(buf) {
  try {
    const d = await crypto.subtle.digest("SHA-256", buf);
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
  } catch { return "sha-unavailable-" + buf.byteLength; }
}
function dbErr(e) {
  const c = e && e.code;
  if (c === "quota_exceeded") return "The review's storage is full. Remove an old review or ask Claude to archive it.";
  if (c === "invalid_argument") return "You don't have permission for that here. Leads and the owner manage reviews; ask them to change your access to Editor if you need to.";
  if (c === "resource_exhausted") return "Too many changes at once. Wait a few seconds and try again.";
  return "That didn't save (" + (c || "error") + "). Try again in a moment.";
}

// ---------------------------------------------------------------- parsers (same rules as platform/api/app/parsers.py)
const P = (() => {
  const YEAR = /(1[5-9]\d\d|20\d\d|21\d\d)/;
  const normDoi = (v) => { if (!v) return null; const s = v.trim().replace(/^(https?:\/\/(dx\.)?doi\.org\/|doi:\s*)/i, "").trim().toLowerCase(); return s || null; };
  const normYear = (v) => { const m = v && String(v).match(YEAR); return m ? Number(m[1]) : null; };
  const strip = (v) => (v == null ? null : v.replace(/[{}]/g, "").replace(/\s+/g, " ").trim());
  const normTitle = (v) => (strip(v) || "").toLowerCase().replace(/[^0-9a-z]+/g, " ").replace(/\s+/g, " ").trim();
  function finish(fields, title, abstract, authors, yearRaw, journal, doi, pmid, kind, raw) {
    const warnings = [];
    title = strip(title);
    if (!title) warnings.push("No title");
    const year = normYear(yearRaw);
    if (yearRaw && year == null) warnings.push("Year not understood: " + yearRaw);
    if (!yearRaw) warnings.push("No year");
    return { raw, fields, warnings, norm: { title, abstract: strip(abstract), authors: authors.map(strip).filter(Boolean), year, journal: strip(journal), doi: normDoi(doi), pmid: pmid && String(pmid).trim() ? String(pmid).trim() : null, kind } };
  }
  const RIS_KIND = { JOUR: "journal", JFULL: "journal", ABST: "conference", CONF: "conference", CPAPER: "conference", DBASE: "registry", CTRIAL: "registry" };
  function ris(text) {
    const entries = [], failures = []; let cur = null, raw = [], last = null, start = 0;
    text.split(/\r?\n/).forEach((line, i) => {
      const n = i + 1, m = line.match(/^([A-Z][A-Z0-9])  -( (.*))?$/);
      if (m) {
        const tag = m[1], val = (m[3] || "").trim();
        if (tag === "TY") { if (cur) failures.push({ position: start, message: `Entry starting at line ${start} has no ER line` }); cur = { TY: [val] }; raw = [line]; start = n; last = "TY"; return; }
        if (!cur) { failures.push({ position: n, message: `Line ${n} is outside any entry (no TY before it)` }); return; }
        raw.push(line);
        if (tag === "ER") { entries.push(risEntry(cur, raw.join("\n"))); cur = null; raw = []; last = null; return; }
        (cur[tag] = cur[tag] || []).push(val); last = tag;
      } else if (cur) { raw.push(line); if (line.trim() && last) cur[last][cur[last].length - 1] = (cur[last][cur[last].length - 1] + " " + line.trim()).trim(); }
    });
    if (cur) failures.push({ position: start, message: `Entry starting at line ${start} has no ER line` });
    return { entries, failures };
  }
  function risEntry(f, raw) {
    const g = (...t) => { for (const x of t) if (f[x] && f[x][0]) return f[x][0]; return null; };
    const an = g("AN"), db = (g("DB") || "").toLowerCase();
    const pmid = an && /^\d+$/.test(an) && (db.includes("pubmed") || db.includes("medline")) ? an : null;
    return finish(f, g("TI", "T1"), g("AB", "N2"), [...(f.AU || []), ...(f.A1 || [])], g("PY", "Y1", "DA"), g("T2", "JO", "JF", "JA"), g("DO"), pmid, RIS_KIND[(g("TY") || "").toUpperCase()] || "other", raw);
  }
  function bibtex(text) {
    const entries = [], failures = []; let i = 0;
    while (true) {
      const at = text.indexOf("@", i); if (at < 0) break;
      const m = text.slice(at).match(/^@\s*([A-Za-z]+)\s*([{(])/);
      if (!m) { i = at + 1; continue; }
      const type = m[1].toLowerCase();
      if (["comment", "preamble", "string"].includes(type)) { i = at + m[0].length; continue; }
      let j = at + m[0].length, depth = 1;
      while (j < text.length && depth) { const c = text[j]; if (c === "{" || c === "(") depth++; else if (c === "}" || c === ")") depth--; j++; }
      const line = text.slice(0, at).split("\n").length;
      if (depth) { failures.push({ position: line, message: `Entry at line ${line} has unbalanced braces` }); break; }
      const raw = text.slice(at, j), body = text.slice(at + m[0].length, j - 1);
      try { entries.push(bibEntry(type, body, raw)); } catch (e) { failures.push({ position: line, message: `Entry at line ${line}: ${e.message}` }); }
      i = j;
    }
    return { entries, failures };
  }
  function bibEntry(type, body, raw) {
    const comma = body.indexOf(","), key = body.slice(0, comma).trim(), rest = body.slice(comma + 1), f = {};
    let k = 0;
    while (k < rest.length) {
      const m = rest.slice(k).match(/^\s*([A-Za-z][\w-]*)\s*=\s*/);
      if (!m) { if (rest.slice(k).replace(/[\s,]/g, "")) throw new Error("field list could not be read"); break; }
      const name = m[1].toLowerCase(); k += m[0].length; let val;
      if (rest[k] === "{") { let d = 1, s = ++k; while (k < rest.length && d) { if (rest[k] === "{") d++; else if (rest[k] === "}") d--; k++; } if (d) throw new Error("unbalanced braces in field " + name); val = rest.slice(s, k - 1); }
      else if (rest[k] === '"') { const e = rest.indexOf('"', k + 1); val = rest.slice(k + 1, e); k = e + 1; }
      else { const mm = rest.slice(k).match(/^[^,]*/); val = mm[0].trim(); k += mm[0].length; }
      f[name] = val.replace(/\s+/g, " ").trim();
      const mm = rest.slice(k).match(/^\s*,?/); k += mm[0].length;
    }
    const authors = (f.author || "").split(/\s+and\s+/).map((a) => a.trim()).filter(Boolean);
    const kind = { article: "journal", inproceedings: "conference", conference: "conference" }[type] || "other";
    return finish({ _type: type, _key: key, ...f }, f.title, f.abstract, authors, f.year, f.journal || f.booktitle, f.doi, f.pmid, kind, raw);
  }
  function csvRows(text) {
    const rows = []; let row = [], cell = "", q = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (q) { if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; }
      else if (c === '"') q = true; else if (c === ",") { row.push(cell); cell = ""; }
      else if (c === "\n" || c === "\r") { if (c === "\r" && text[i + 1] === "\n") i++; row.push(cell); rows.push(row); row = []; cell = ""; }
      else cell += c;
    }
    if (cell !== "" || row.length) { row.push(cell); rows.push(row); }
    return rows;
  }
  const CSV_KIND = { journal: "journal", article: "journal", conference: "conference", abstract: "conference", registry: "registry", trial: "registry" };
  function csv(text) {
    const rows = csvRows(text.replace(/^﻿/, "")); const entries = [], failures = [];
    if (!rows.length) return { entries, failures: [{ position: 1, message: "The file is empty" }] };
    const cols = rows[0].map((c) => c.trim().toLowerCase());
    if (!cols.includes("title")) return { entries, failures: [{ position: 1, message: "No 'title' column in the header row" }] };
    rows.slice(1).forEach((r, i) => {
      const n = i + 2; if (!r.some((c) => c.trim())) return;
      if (r.length !== cols.length) { failures.push({ position: n, message: `Row ${n} has ${r.length} columns; the header has ${cols.length}` }); return; }
      const f = Object.fromEntries(cols.map((c, j) => [c, r[j]]));
      const raw = r.map((c) => (/[",\n]/.test(c) ? '"' + c.replace(/"/g, '""') + '"' : c)).join(",");
      entries.push(finish(f, f.title, f.abstract, (f.authors || "").split(";").map((a) => a.trim()).filter(Boolean), f.year, f.journal, f.doi, f.pmid, CSV_KIND[(f.type || "journal").trim().toLowerCase()] || "other", raw));
    });
    return { entries, failures };
  }
  const detect = (name) => { name = name.toLowerCase(); if (/\.(ris|txt)$/.test(name)) return "ris"; if (/\.(bib|bibtex)$/.test(name)) return "bibtex"; if (/\.csv$/.test(name)) return "csv"; return null; };
  return { ris, bibtex, csv, detect, normTitle };
})();

// ---------------------------------------------------------------- duplicates (same rules as platform/api/app/dedup.py)
const NOTICE = /\b(correction|corrigendum|erratum|retraction|retracted|comment|reply|protocol)\b/i;
function detectDuplicates(pubs) {
  const live = Object.entries(pubs).filter(([, p]) => !p.mergedInto).map(([id, p]) => ({ id, ...p }));
  const found = new Map();
  const add = (a, b, rule, score) => { const [x, y] = a.id < b.id ? [a, b] : [b, a]; const k = x.id + "|" + y.id; if (!found.has(k) || found.get(k).score < score) found.set(k, { a: x.id, b: y.id, rule, score, ax: x, bx: y }); };
  const by = { doi: {}, pmid: {}, title: {} };
  for (const p of live) {
    if (p.doi) (by.doi[p.doi] = by.doi[p.doi] || []).push(p);
    if (p.pmid) (by.pmid[p.pmid] = by.pmid[p.pmid] || []).push(p);
    const t = P.normTitle(p.title); if (t) (by.title[t] = by.title[t] || []).push(p);
  }
  const pairs = (g, f) => { for (let i = 0; i < g.length; i++) for (let j = i + 1; j < g.length; j++) f(g[i], g[j]); };
  for (const g of Object.values(by.doi)) pairs(g, (a, b) => add(a, b, "doi", 1));
  for (const g of Object.values(by.pmid)) pairs(g, (a, b) => add(a, b, "pmid", 1));
  for (const g of Object.values(by.title)) pairs(g, (a, b) => { if (a.year == null || b.year == null || Math.abs(a.year - b.year) <= 1) add(a, b, "title_year", 0.9); });
  return [...found.values()].map(({ a, b, rule, score, ax, bx }) => {
    const blockers = [];
    for (const p of [ax, bx]) if (p.title && NOTICE.test(p.title)) blockers.push("correction or notice");
    if (ax.kind !== bx.kind) blockers.push("different publication type");
    return { a, b, rule, score, blockers, status: "open" };
  });
}

// ---------------------------------------------------------------- decisions (spec §8)
function statusOf(votes, stage) {
  // votes: array of {d, r} for every assigned reviewer, or null when one is missing
  if (!votes.length) return { status: "unassigned" };
  if (votes.some((v) => !v)) return { status: "waiting" };
  const n = votes.length, exc = votes.filter((v) => v.d === "exclude"), inc = votes.filter((v) => v.d === "include").length, may = votes.filter((v) => v.d === "maybe").length;
  if (exc.length === n) {
    if (stage === "ft" && new Set(exc.map((v) => v.r || "")).size > 1) return { status: "conflict" };
    return { status: "excluded" };
  }
  if (exc.length > 0) return { status: "conflict" };
  if (stage === "ft" && may > 0) return { status: "conflict" };
  return { status: "included", uncertain: stage === "ta" && may > 0 && inc + may === n };
}

// What the viewer may know about pid at a stage: own vote always; others' only once released.
function teamView(pid, stage) {
  const assigned = (S.assign[stage] || {})[pid] || [];
  const rel = S.released[stage] || {};
  const allReleased = assigned.length > 0 && assigned.every((u) => rel[u] && rel[u].done);
  const votes = assigned.map((u) => (allReleased ? rel[u].votes[pid] || null : null));
  const res = S.resolutions[stage + "_" + pid];
  if (!allReleased) return { assigned, revealed: false, status: assigned.length ? "blinded" : "unassigned", final: null, votes: [], resolution: null };
  const st = statusOf(votes, stage);
  let final = res ? res.decision : st.status === "included" ? "include" : st.status === "excluded" ? "exclude" : null;
  return { assigned, revealed: true, ...st, final, votes: assigned.map((u, i) => ({ uid: u, ...(votes[i] || {}) })), resolution: res || null };
}

function eligible(stage) {
  const live = Object.keys(S.pubs).filter((id) => !S.pubs[id].mergedInto).sort();
  if (stage === "ta") return live;
  return live.filter((id) => teamView(id, "ta").final === "include");
}

// ---------------------------------------------------------------- subscriptions
function subscribeReview(rid) {
  S.unsub.forEach((u) => u()); S.unsub = []; S.relUnsub.forEach((u) => u()); S.relUnsub = [];
  S.ready.assign = {}; S.ready.stages = {};
  Object.assign(S, { fulltext: {}, extraction: {}, analysis: [], requests: {}, manuscript: null, xsel: null, aiDraft: null, setup: { outcomes: [], studyFields: ["Design", "Country", "Follow-up"], arms: ["Intervention", "Control"] } });
  Object.assign(S, { pubs: {}, imports: [], members: {}, dedup: { candidates: [], log: [] }, assign: { ta: {}, ft: {} }, stages: {}, resolutions: {}, retrieval: {}, released: {}, sel: null });
  const base = `reviews/${rid}`;
  const sub = (ref, fn) => S.unsub.push(ref.onSnapshot(fn, (e) => say(dbErr(e), true)));
  sub(S.db.collection(base + "/pubs"), (snap) => { const all = {}; snap.docs.forEach((d) => Object.assign(all, (d.data() || {}).items || {})); S.pubs = all; render(); });
  sub(S.db.collection(base + "/imports").orderBy("at"), (snap) => { S.imports = snap.docs.map((d) => ({ id: d.id, ...d.data() })); render(); });
  sub(S.db.collection(base + "/members"), (snap) => { S.members = Object.fromEntries(snap.docs.map((d) => [d.id, d.data()])); resolveNames(); watchReleases(); render(); });
  sub(S.db.doc(base + "/meta/dedup"), (d) => { S.dedup = d.exists ? d.data() : { candidates: [], log: [] }; render(); });
  sub(S.db.doc(base + "/meta/retrieval"), (d) => { S.retrieval = d.exists ? d.data().map || {} : {}; render(); });
  for (const st of Object.keys(STAGES)) {
    sub(S.db.doc(`${base}/assign/${st}`), (d) => { S.assign[st] = d.exists ? d.data().map || {} : {}; if (!d.metadata.fromCache) S.ready.assign[st] = true; maybeRelease(st); render(); });
    sub(S.db.doc(`${base}/stages/${st}`), (d) => { S.stages[st] = d.exists ? d.data() : {}; if (!d.metadata.fromCache) S.ready.stages[st] = true; maybeRelease(st); render(); });
  }
  sub(S.db.doc(base + "/meta/fulltext"), (d) => { S.fulltext = d.exists ? d.data().map || {} : {}; render(); });
  sub(S.db.doc(base + "/meta/setup"), (d) => { if (d.exists) S.setup = { ...S.setup, ...d.data() }; render(); });
  sub(S.db.doc(base + "/meta/manuscript"), (d) => { S.manuscript = d.exists ? d.data() : null; render(); });
  sub(S.db.collection(base + "/analysis"), (snap) => { S.analysis = snap.docs.map((d) => ({ id: d.id, ...d.data() })); render(); });
  sub(S.db.collection(base + "/requests"), (snap) => { S.requests = Object.fromEntries(snap.docs.map((d) => [d.id, d.data()])); render(); });
  sub(S.db.collection("extraction").where("rid", "==", rid), (snap) => { S.extraction = Object.fromEntries(snap.docs.map((d) => [d.data().pid, d.data()])); render(); });
  sub(S.db.collection(base + "/resolutions"), (snap) => { S.resolutions = Object.fromEntries(snap.docs.map((d) => [d.id, d.data()])); render(); });
  sub(S.db.collection("progress"), (snap) => { S.progress = Object.fromEntries(snap.docs.map((d) => [d.id, d.data()])); resolveNames(); render(); });
}

function watchReleases() {
  S.relUnsub.forEach((u) => u()); S.relUnsub = []; S.released = {};
  for (const uid of Object.keys(S.members).filter((u) => u !== CLAUDE)) {
    const q = S.db.collection(`released/${uid}/r`).where("rid", "==", S.rid);
    S.relUnsub.push(q.onSnapshot((snap) => {
      for (const st of Object.keys(STAGES)) {
        const all = snap.docs.map((d) => d.data()).filter((x) => x.stage === st);
        const S2 = (S.released[st] = S.released[st] || {});
        for (const who of [uid, CLAUDE]) {
          const docs = all.filter((x) => (x.reviewer || uid) === who);
          if (who === CLAUDE && !all.some((x) => x.reviewer === CLAUDE)) continue;
          if (!docs.length) { delete S2[who]; continue; }
          const votes = {}; let done = false;
          docs.forEach((x) => { Object.assign(votes, x.votes || {}); if (x.final) done = true; });
          S2[who] = { votes, done: done && docs.length >= (docs.find((x) => x.final) || {}).chunks };
        }
      }
      render();
    }, (e) => say(dbErr(e), true)));
  }
}

let myVotesUnsub = null;
function subscribeMine() {
  if (myVotesUnsub) myVotesUnsub();
  myVotesUnsub = S.db.collection("data/users/" + S.uid).onSnapshot((snap) => {
    const votes = {}, ai = {}, cv = {};
    snap.docs.forEach((d) => {
      const x = d.data() || {};
      if (d.id.startsWith("v_")) { const [, rid, st] = d.id.split("_"); const k = rid + "_" + st; votes[k] = Object.assign(votes[k] || {}, x.items || {}); }
      if (d.id.startsWith("ai_")) Object.assign(ai, x.items || {});
      if (d.id.startsWith("c_")) { const [, rid, st] = d.id.split("_"); const k = rid + "_" + st; cv[k] = Object.assign(cv[k] || {}, x.items || {}); }
    });
    S.myVotes = votes; S.myAi = ai; S.claudeVotes = cv; if (!snap.metadata.fromCache) S.ready.mine = true;
    for (const st of Object.keys(STAGES)) maybeRelease(st);
    render();
  }, (e) => say(dbErr(e), true));
}

async function resolveNames() {
  if (!S.user || !S.user.profiles) return;
  const ids = [...new Set([...Object.keys(S.members), ...Object.keys(S.progress)])];
  if (!ids.length) return;
  try { const ps = await S.user.profiles(ids); for (const id of ids) if (ps[id] && ps[id].name) S.names[id] = ps[id].name; render(); } catch { /* names are optional */ }
}

// ---------------------------------------------------------------- actions
async function createReview(title, criteria) {
  const rid = "r" + Date.now().toString(36);
  try {
    await S.db.doc("reviews/" + rid).set({ title, criteria, reasonsFt: ["Wrong population", "Wrong intervention", "Wrong comparator", "Wrong outcome", "Wrong study design"], createdBy: S.uid, createdAt: nowIso(), blind: true });
    await S.db.doc(`reviews/${rid}/members/${S.uid}`).set({ role: "lead", addedBy: S.uid, at: nowIso() });
    await audit(rid, "create review", { title });
    openReview(rid);
  } catch (e) { say(dbErr(e), true); }
}

async function audit(rid, action, detail) {
  try { await S.db.collection(`reviews/${rid}/audit`).add({ action, detail: detail || {}, by: S.uid, at: nowIso() }); } catch { /* audit is best effort for non-editors */ }
}

async function importFile(file) {
  const fmt = P.detect(file.name);
  if (!fmt) return say("Use a .ris, .bib or .csv file.", true);
  const buf = await file.arrayBuffer(), sha = await sha256(buf);
  if (S.imports.some((b) => b.sha256 === sha)) return say(`This exact file was already imported (${S.imports.find((b) => b.sha256 === sha).filename}).`, true);
  let text; try { text = new TextDecoder("utf-8", { fatal: true }).decode(buf); } catch { text = new TextDecoder("latin1").decode(buf); }
  const { entries, failures } = P[fmt](text);
  const bid = "b" + pad(S.imports.length + 1, 3);
  let next = Object.keys(S.pubs).length;
  const newPubs = {}, srcItems = [];
  entries.forEach((e, i) => {
    const pid = "p" + pad(next++), sid = `${bid}-${pad(i + 1)}`;
    srcItems.push({ sid, raw: e.raw, warnings: e.warnings });
    newPubs[pid] = { ...e.norm, sources: [sid], file: file.name, mergedInto: null };
  });
  say(`Saving ${entries.length} references…`);
  try {
    const base = `reviews/${S.rid}`;
    for (let c = 0; c * CHUNK < srcItems.length; c++) await S.db.doc(`${base}/sources/${bid}_${pad(c, 3)}`).set({ items: srcItems.slice(c * CHUNK, (c + 1) * CHUNK) });
    const byChunk = {};
    for (const [pid, p] of Object.entries(newPubs)) (byChunk[chunkOf(pid)] = byChunk[chunkOf(pid)] || {})[pid] = p;
    for (const [c, items] of Object.entries(byChunk)) {
      const ref = S.db.doc(`${base}/pubs/c${pad(Number(c), 3)}`);
      await serialWrite(ref.path, async () => { const d = await ref.get(); await ref.set({ items: { ...((d.exists && d.data().items) || {}), ...items } }); });
    }
    const summary = { filename: file.name, format: fmt, sha256: sha, entries: entries.length + failures.length, imported: entries.length, warnings: entries.filter((e) => e.warnings.length).length, failed: failures.length, failures: failures.slice(0, 50), by: S.uid, at: nowIso() };
    await S.db.doc(`${base}/imports/${bid}`).set(summary);
    await audit(S.rid, "import", { filename: file.name, imported: entries.length, failed: failures.length });
    say(`${file.name}: ${summary.entries} entries found, ${summary.imported} imported, ${summary.warnings} with warnings, ${summary.failed} failed.` + (failures.length ? " " + failures.map((f) => f.message).join("; ") : ""), failures.length > 0);
  } catch (e) { say(dbErr(e), true); }
}

async function savePubs(changes) {
  // changes: {pid: partialPub}
  const byChunk = {};
  for (const [pid, ch] of Object.entries(changes)) (byChunk[chunkOf(pid)] = byChunk[chunkOf(pid)] || {})[pid] = ch;
  for (const [c, items] of Object.entries(byChunk)) {
    const ref = S.db.doc(`reviews/${S.rid}/pubs/c${pad(Number(c), 3)}`);
    await serialWrite(ref.path, async () => { const d = await ref.get(); const cur = (d.exists && d.data().items) || {}; for (const [pid, ch] of Object.entries(items)) cur[pid] = { ...cur[pid], ...ch }; await ref.set({ items: cur }); });
  }
}
const rootOf = (pid) => { let p = pid; while (S.pubs[p] && S.pubs[p].mergedInto) p = S.pubs[p].mergedInto; return p; };
async function saveDedup(d) { const ref = S.db.doc(`reviews/${S.rid}/meta/dedup`); await serialWrite(ref.path, () => ref.set(d)); }

async function findDuplicates() {
  const fresh = detectDuplicates(S.pubs), old = S.dedup.candidates || [];
  const key = (c) => c.a + "|" + c.b, known = new Set(old.map(key));
  const added = fresh.filter((c) => !known.has(key(c)));
  try { await saveDedup({ candidates: [...old, ...added], log: [...(S.dedup.log || []), { at: nowIso(), by: S.uid, action: "detect", added: added.length }] }); say(`${added.length} new pairs to check.`); }
  catch (e) { say(dbErr(e), true); }
}
async function decideCandidate(i, action) {
  const cands = [...S.dedup.candidates], c = { ...cands[i] };
  const anyAssigned = (pid) => Object.values(S.assign).some((m) => m[pid]);
  try {
    if (action === "merge") {
      const a = rootOf(c.a), b = rootOf(c.b);
      if (a !== b) {
        const [keep, drop] = a < b ? [a, b] : [b, a];
        if (anyAssigned(drop) || anyAssigned(keep)) return say("One of these is already assigned for screening. Merge duplicates before assigning.", true);
        await savePubs({ [drop]: { mergedInto: keep } });
      }
    }
    c.status = action === "merge" ? "merged" : "not duplicates"; c.by = S.uid; c.at = nowIso(); cands[i] = c;
    await saveDedup({ candidates: cands, log: [...(S.dedup.log || []), { at: nowIso(), by: S.uid, action, a: c.a, b: c.b }] });
    say(action === "merge" ? "Merged. You can undo it from the publication's row." : "Marked as not duplicates.");
  } catch (e) { say(dbErr(e), true); }
}
async function autoMerge() {
  const idx = (S.dedup.candidates || []).map((c, i) => [c, i]).filter(([c]) => c.status === "open" && c.score >= 1 && !c.blockers.length).map(([, i]) => i);
  for (const i of idx) await decideCandidate(i, "merge");
  say(`${idx.length} exact DOI/PMID pairs merged. Each merge can be undone.`);
}
async function unmerge(pid) {
  try { await savePubs({ [pid]: { mergedInto: null } }); await saveDedup({ ...S.dedup, log: [...(S.dedup.log || []), { at: nowIso(), by: S.uid, action: "undo merge", pid }] }); say("Merge undone."); }
  catch (e) { say(dbErr(e), true); }
}

async function addMember(uid, role) {
  try { await S.db.doc(`reviews/${S.rid}/members/${uid}`).set({ role, addedBy: S.uid, at: nowIso() }); await audit(S.rid, "add member", { uid, role }); say("Member added."); }
  catch (e) { say(dbErr(e), true); }
}

async function assignAll(stage, uids) {
  const per = 2, map = { ...(S.assign[stage] || {}) }; let added = 0;
  for (const pid of eligible(stage)) {
    const have = map[pid] || [], want = uids.filter((u) => !have.includes(u));
    if (have.length + want.length > per) continue;
    map[pid] = [...have, ...want]; added += want.length;
  }
  try { const ref = S.db.doc(`reviews/${S.rid}/assign/${stage}`); await serialWrite(ref.path, () => ref.set({ map })); await audit(S.rid, "assign", { stage, uids, added }); say(`${added} assignments added.`); }
  catch (e) { say(dbErr(e), true); }
}

// Lead controls follow the role given inside the review, because on plans without a Contributor level
// every reviewer has to be an Editor of the page. (The database cannot tell a lead Editor from a reviewer Editor.)
function isLead() { return S.isOwner || (S.canEdit && ((S.members[S.uid] || {}).role === "lead")); }
function roleLabel() { if (S.isOwner) return "Owner"; const m = S.rid && S.members[S.uid]; if (m) return m.role === "lead" ? "Lead" : "Reviewer"; return S.canEdit ? "Editor" : "Viewer (read only)"; }

function myVote(pid, stage) { return ((S.myVotes[S.rid + "_" + stage] || {})[pid]) || null; }
async function castVote(pid, stage, d, reason) {
  if ((S.stages[stage] || {}).open) return say("Voting is closed: reconciliation is open for this stage.", true);
  if (stage === "ft" && d === "exclude" && !reason) return say("Choose a reason for excluding at full text.", true);
  const prev = myVote(pid, stage), hist = [...((prev && prev.h) || []), { d, r: reason || null, t: nowIso() }];
  const ref = S.db.doc(`data/users/${S.uid}/v_${S.rid}_${stage}_${pad(chunkOf(pid), 3)}`);
  try {
    await serialWrite(ref.path, async () => { const cur = await ref.get(); const items = (cur.exists && cur.data().items) || {}; items[pid] = { d, r: reason || null, t: nowIso(), h: hist }; await ref.set({ items }); });
    await updateProgress(stage, pid);
    say(prev ? `Changed to ${d}. Your earlier vote is kept in your history.` : `Saved: ${d}.`);
  } catch (e) { say(dbErr(e), true); }
}
async function updateProgress(stage, justVoted) {
  const mine = Object.entries(S.assign[stage] || {}).filter(([, us]) => us.includes(S.uid)).map(([p]) => p);
  const votes = S.myVotes[S.rid + "_" + stage] || {};
  const voted = mine.filter((p) => votes[p] || p === justVoted).length;
  const ref = S.db.doc("progress/" + S.uid), key = S.rid + "_" + stage;
  await serialWrite(ref.path, async () => { const d = await ref.get(); const cur = (d.exists && d.data()) || {}; cur[key] = { assigned: mine.length, voted, at: nowIso() }; await ref.set(cur); });
}

// When the lead opens reconciliation, my page publishes my votes for that stage (once).
let releasing = {};
async function maybeRelease(stage) {
  const st = S.stages[stage] || {};
  releaseClaude(stage);
  if (!st.open || !S.rid || releasing[S.rid + stage]) return;
  if (!S.ready.mine || !S.ready.assign[stage] || !S.ready.stages[stage]) return;   // never publish before my votes have loaded
  const mine = Object.entries(S.assign[stage] || {}).filter(([, us]) => us.includes(S.uid)).map(([p]) => p);
  if (!mine.length) return;
  const ref0 = S.db.doc(`released/${S.uid}/r/${S.rid}_${stage}_000`);
  releasing[S.rid + stage] = true;
  try {
    const existing = await ref0.get();
    if (existing.exists && existing.data().final) return;
    const votes = S.myVotes[S.rid + "_" + stage] || {};
    const items = mine.filter((p) => votes[p]).map((p) => [p, { d: votes[p].d, r: votes[p].r, first: votes[p].h && votes[p].h[0] ? votes[p].h[0].d : votes[p].d, changes: Math.max(0, (votes[p].h || []).length - 1) }]);
    const chunks = Math.max(1, Math.ceil(items.length / 400));
    for (let c = chunks - 1; c >= 0; c--) {
      await S.db.doc(`released/${S.uid}/r/${S.rid}_${stage}_${pad(c, 3)}`).set({ rid: S.rid, stage, chunks, final: c === 0, at: nowIso(), votes: Object.fromEntries(items.slice(c * 400, (c + 1) * 400)) });
    }
    say("Reconciliation is open: your votes for this stage are now visible to the team.");
  } catch (e) { say(dbErr(e), true); releasing[S.rid + stage] = false; }
}

async function releaseClaude(stage) {
  if (!S.isOwner || !S.rid || releasing["claude" + S.rid + stage] || !S.ready.mine || !S.ready.assign[stage] || !S.ready.stages[stage]) return;
  const mine = Object.entries(S.assign[stage] || {}).filter(([, us]) => us.includes(CLAUDE)).map(([p]) => p);
  if (!mine.length || !(S.stages[stage] || {}).open) return;
  const ref0 = S.db.doc(`released/${S.uid}/r/${S.rid}_${stage}_claude_000`);
  releasing["claude" + S.rid + stage] = true;
  try {
    const ex = await ref0.get(); if (ex.exists && ex.data().final) return;
    const votes = S.claudeVotes[S.rid + "_" + stage] || {};
    const items = mine.filter((p) => votes[p]).map((p) => [p, { d: votes[p].d, r: votes[p].r || null, first: votes[p].h && votes[p].h[0] ? votes[p].h[0].d : votes[p].d, quote: votes[p].quote || "", changes: Math.max(0, (votes[p].h || []).length - 1) }]);
    const chunks = Math.max(1, Math.ceil(items.length / 400));
    for (let c = chunks - 1; c >= 0; c--) await S.db.doc(`released/${S.uid}/r/${S.rid}_${stage}_claude_${pad(c, 3)}`).set({ rid: S.rid, stage, reviewer: CLAUDE, chunks, final: c === 0, at: nowIso(), votes: Object.fromEntries(items.slice(c * 400, (c + 1) * 400)) });
  } catch (e) { say(dbErr(e), true); releasing["claude" + S.rid + stage] = false; }
}

async function openReconciliation(stage) {
  try { await S.db.doc(`reviews/${S.rid}/stages/${stage}`).set({ open: true, by: S.uid, at: nowIso() }); await audit(S.rid, "open reconciliation", { stage }); say("Reconciliation opened. Voting is closed for this stage; each reviewer's votes appear once their page publishes them."); }
  catch (e) { say(dbErr(e), true); }
}
async function resolve(pid, stage, decision, note, reason) {
  if (!note.trim()) return say("Write how the disagreement was settled.", true);
  try { await S.db.doc(`reviews/${S.rid}/resolutions/${stage}_${pid}`).set({ decision, note, reason: reason || null, by: S.uid, at: nowIso() }); await audit(S.rid, "resolve", { stage, pid, decision }); say("Resolution saved. The reviewers' votes are unchanged."); }
  catch (e) { say(dbErr(e), true); }
}
async function setRetrieval(pid, status) {
  const ref = S.db.doc(`reviews/${S.rid}/meta/retrieval`);
  try { await serialWrite(ref.path, async () => { const d = await ref.get(); const map = (d.exists && d.data().map) || {}; map[pid] = { status, by: S.uid, at: nowIso() }; await ref.set({ map }); }); }
  catch (e) { say(dbErr(e), true); }
}

async function askClaude(pid, stage) {
  if (!S.sample) return;
  const p = S.pubs[pid];
  const prompt = `You help screen studies for a systematic review. Eligibility criteria:\n${S.review.criteria || "(none written)"}\n\nRecord (${STAGES[stage]} stage):\nTitle: ${p.title}\nYear: ${p.year || "?"}\nAbstract: ${p.abstract || "(no abstract)"}\n\nReply with JSON only: {"suggestion":"include"|"maybe"|"exclude","reason":"one sentence naming the criterion","quote":"the shortest phrase from the record that supports it, copied exactly, or empty"}. Use "maybe" when the record does not give enough information.`;
  say("Asking Claude…");
  try {
    const out = await S.sample(prompt, { modelTier: "quick" });
    const m = (out.text || "").match(/\{[\s\S]*\}/);
    const j = m ? JSON.parse(m[0]) : null;
    if (!j || !DEC.includes(j.suggestion)) throw { message: "unreadable answer" };
    const quoteOk = !j.quote || ((p.title || "") + " " + (p.abstract || "")).includes(j.quote);
    const ref = S.db.doc(`data/users/${S.uid}/ai_${S.rid}`);
    await serialWrite(ref.path, async () => { const d = await ref.get(); const items = (d.exists && d.data().items) || {}; items[stage + "_" + pid] = { ...j, quoteFound: quoteOk, at: nowIso() }; await ref.set({ items }); });
    say("Claude's suggestion is shown under the abstract. It is not a vote.");
  } catch (e) { say(e && e.code === "not_granted" ? "Claude is not available on this page." : "Claude could not answer just now. Try again later.", true); }
}

function exportRows(stage) {
  const reviewers = Object.keys(S.members);
  return eligible(stage).map((pid) => {
    const p = S.pubs[pid], v = teamView(pid, stage), mine = myVote(pid, stage);
    const row = { publication_id: pid, title: p.title || "", year: p.year || "", doi: p.doi || "", pmid: p.pmid || "", kind: p.kind, source_file: p.file || "", status: v.revealed ? v.status : mine ? "voted" : "pending", final_decision: v.final || "", resolution_note: v.resolution ? v.resolution.note : "" };
    for (const u of reviewers) {
      const nm = fullName(u).replace(/[",]/g, " ");
      const x = v.revealed ? v.votes.find((y) => y.uid === u) : null;
      row["first_vote " + nm] = x ? x.first || "" : u === S.uid ? (mine && mine.h ? mine.h[0].d : "") : "[blinded]";
      row["current_vote " + nm] = x ? x.d || "" : u === S.uid ? (mine ? mine.d : "") : "[blinded]";
    }
    return row;
  });
}
const toCsv = (rows) => { if (!rows.length) return ""; const cols = [...new Set(rows.flatMap(Object.keys))]; const q = (s) => (/[",\n]/.test(String(s)) ? '"' + String(s).replace(/"/g, '""') + '"' : String(s)); return [cols.join(","), ...rows.map((r) => cols.map((c) => q(r[c] ?? "")).join(","))].join("\n"); };
function toRis(stage) {
  return eligible(stage).filter((pid) => teamView(pid, stage).final === "include").map((pid) => {
    const p = S.pubs[pid];
    return [`TY  - ${{ conference: "CONF", registry: "DBASE" }[p.kind] || "JOUR"}`, `TI  - ${p.title || ""}`, ...(p.authors || []).map((a) => `AU  - ${a}`), `PY  - ${p.year || ""}`, `T2  - ${p.journal || ""}`, p.doi ? `DO  - ${p.doi}` : null, p.pmid ? `AN  - ${p.pmid}` : null, `AB  - ${p.abstract || ""}`, `N1  - FishingMeta ${pid}`, "ER  -", ""].filter((x) => x != null).join("\n");
  }).join("\n");
}
async function download(filename, data) {
  if (!S.downloads) return say("Downloads are not available in this view.", true);
  try { await S.downloads.save({ filename, data }); } catch (e) { if (e.code !== "declined") say("The download didn't start (" + e.code + ").", true); }
}
function kappa(stage) {
  const pairs = {};
  for (const pid of eligible(stage)) {
    const v = teamView(pid, stage); if (!v.revealed || v.votes.length !== 2 || v.votes.some((x) => !x.first)) continue;
    const k = v.votes.map((x) => x.uid).join("|"); (pairs[k] = pairs[k] || []).push([v.votes[0].first, v.votes[1].first]);
  }
  return Object.entries(pairs).map(([k, obs]) => {
    const n = obs.length, po = obs.filter(([a, b]) => a === b).length / n;
    const pe = DEC.reduce((s, c) => s + (obs.filter(([a]) => a === c).length / n) * (obs.filter(([, b]) => b === c).length / n), 0);
    return { pair: k.split("|"), n, po, kappa: pe === 1 ? null : (po - pe) / (1 - pe) };
  });
}

// ---------------------------------------------------------------- rendering
function renderMsg() {
  const el = $("#msg"); if (!el) return;
  el.textContent = S.msg ? S.msg.text : ""; el.className = S.msg && S.msg.isErr ? "msg err" : "msg";
}
function openReview(rid) { S.rid = rid; S.review = S.reviews.find((r) => r.id === rid) || null; S.tab = "overview"; subscribeReview(rid); try { location.hash = rid; } catch {} render(); }

let pendingRender = false;
function render() {
  const a = document.activeElement;
  if (a && a.closest && a.closest("#app") && (a.tagName === "TEXTAREA" || (a.tagName === "INPUT" && a.type !== "checkbox" && a.type !== "file" && a.value))) { pendingRender = true; return; }
  pendingRender = false;
  const app = $("#app");
  const scrollQ = $(".queue") ? $(".queue").scrollTop : 0;
  app.replaceChildren(header(), h("p", { id: "msg", class: "msg", role: "status", "aria-live": "polite" }), S.rid && S.review ? reviewView() : homeView());
  renderMsg();
  if ($(".queue")) $(".queue").scrollTop = scrollQ;
}
function header() {
  return h("header", { class: "top" },
    h("a", { class: "brand", href: "#", onclick: (e) => { e.preventDefault(); S.rid = null; S.review = null; S.unsub.forEach((u) => u()); S.unsub = []; try { history.replaceState(null, "", " "); } catch {} render(); } }, h("img", { src: LOGO, alt: "" }), h("span", { class: "name" }, "FishingMeta")),
    S.review ? h("span", { class: "crumb" }, S.review.title) : null,
    h("span", { class: "who" }, S.user ? roleLabel() : ""));
}

function homeView() {
  if (!S.db) return h("main", { class: "panel" }, h("h1", {}, "FishingMeta"), h("p", {}, "Sign in to claude.ai to open your team's reviews."));
  return h("main", {},
    h("section", { class: "panel" },
      h("h1", {}, "Reviews"),
      S.reviews.length ? h("ul", { class: "reviews" }, S.reviews.map((r) => h("li", {}, h("button", { class: "linkish", onclick: () => openReview(r.id) }, r.title), h("span", { class: "note" }, " · created " + (r.createdAt || "").slice(0, 10))))) : h("p", { class: "note" }, S.canEdit ? "No reviews yet. Create the first one below." : "No reviews yet. A lead will create one and add you to it."),
      !S.canEdit && S.user ? h("p", { class: "banner" }, "You can read this page but not save anything. Ask the owner to invite your e-mail as Editor in the Share menu.") : null),
    S.isOwner ? h("section", { class: "panel" },
      h("h2", {}, "Create a review"),
      h("form", { onsubmit: (e) => { e.preventDefault(); const f = new FormData(e.target); if (String(f.get("title")).trim()) createReview(String(f.get("title")).trim(), String(f.get("criteria") || "")); } },
        h("label", { for: "nr-title" }, "Title"), h("input", { id: "nr-title", name: "title", required: true }),
        h("label", { for: "nr-crit" }, "Eligibility criteria (shown to reviewers and to Claude when it suggests)"), h("textarea", { id: "nr-crit", name: "criteria", rows: 4 }),
        h("button", { class: "primary", type: "submit" }, "Create review"))) : null);
}

function reviewView() {
  const lead = isLead();
  const tabs = [["overview", "Overview"], lead && ["import", "Import and duplicates"], ["screen", "Title and abstract"], ["fulltext", "Full text"], ["reconcile", "Reconciliation"], ["extract", "Data extraction"], ["prisma", "PRISMA"], ["analysis", "Analysis"], ["manuscript", "Manuscript"], ["export", "Export"]].filter(Boolean);
  const body = { overview: overviewTab, import: importTab, screen: () => screenTab("ta"), fulltext: () => screenTab("ft"), reconcile: reconcileTab, extract: extractTab, prisma: prismaTab, analysis: analysisTab, manuscript: manuscriptTab, export: exportTab }[S.tab] || overviewTab;
  return h("main", {},
    h("nav", { class: "tabs", "aria-label": "Review sections" }, tabs.map(([k, l]) => h("button", { "aria-current": S.tab === k ? "page" : null, onclick: () => { S.tab = k; S.msg = ""; render(); } }, l))),
    body());
}

function stagePicker() {
  return h("label", { class: "row" }, "Stage ", h("select", { id: "stage", onchange: (e) => { S.stage = e.target.value; S.sel = null; render(); } }, Object.entries(STAGES).map(([k, l]) => h("option", { value: k, selected: S.stage === k }, l))));
}

function overviewTab() {
  const live = Object.values(S.pubs).filter((p) => !p.mergedInto).length, total = Object.values(S.pubs).reduce((s, p) => s + (p.sources || []).length, 0);
  const rows = Object.keys(STAGES).map((st) => {
    const el = eligible(st); let rev = 0; const counts = {};
    for (const pid of el) { const v = teamView(pid, st); if (v.revealed) { rev++; const k = v.final === "include" ? "included" : v.final === "exclude" ? "excluded" : v.status; counts[k] = (counts[k] || 0) + 1; } }
    const label = rev ? Object.entries(counts).map(([k, n]) => `${k} ${n}`).join(" · ") + (rev < el.length ? ` · still blinded ${el.length - rev}` : "") : "Blinded until reconciliation";
    return h("tr", {}, h("th", {}, STAGES[st]), h("td", { class: "num" }, String(el.length)), h("td", {}, label));
  });
  const prog = Object.entries(S.progress).flatMap(([uid, m]) => [[uid, m[S.rid + "_" + S.stage]], [CLAUDE, m[S.rid + "_" + S.stage + "_claude"]]]).filter(([, x]) => x);
  const lead = isLead();
  return h("div", {},
    progressPies(),
    h("section", { class: "panel" },
      h("h2", {}, "Summary"),
      h("p", {}, `${total} records imported · ${total - live} duplicates merged · ${live} publications to screen`),
      h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "Stage"), h("th", {}, "Publications"), h("th", {}, "Team results you may see"))), h("tbody", {}, rows)),
      h("p", { class: "note" }, "Team results appear only after reconciliation opens, so nobody's screening is influenced by another reviewer's decisions.")),
    h("section", { class: "panel" },
      h("div", { class: "row spread" }, h("h2", {}, "Progress"), stagePicker()),
      prog.length ? h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "Reviewer"), h("th", {}, "Voted"), h("th", {}, "Assigned"))), h("tbody", {}, prog.map(([uid, x]) => h("tr", {}, h("td", {}, nameOf(uid)), h("td", { class: "num" }, String(x.voted)), h("td", { class: "num" }, String(x.assigned)))))) : h("p", { class: "note" }, "No votes yet at this stage."),
      h("p", { class: "note" }, "Only counts are shared while screening; decisions stay private to each reviewer.")),
    h("section", { class: "panel" },
      h("h2", {}, "Team"),
      h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "Name"), h("th", {}, "Role in this review"))), h("tbody", {}, Object.entries(S.members).map(([uid, m]) => h("tr", {}, h("td", {}, nameOf(uid)), h("td", {}, m.role))))),
      lead ? memberPicker() : null,
      h("p", { class: "note" }, "To add someone: in the page's Share menu, invite their e-mail as Editor (Viewers and Commenters cannot save votes), keep general access restricted (not \"anyone with the link\"), then add them here as Reviewer or Lead. Only leads see assignment, reconciliation and resolution controls.")),
    lead ? h("section", { class: "panel" },
      h("h2", {}, "Assign publications"),
      h("p", { class: "note" }, "Assigns every eligible publication that still has room (two reviewers each) to the people you tick."),
      h("form", { onsubmit: (e) => { e.preventDefault(); const f = new FormData(e.target); const uids = f.getAll("uid"); if (uids.length) assignAll(String(f.get("stage")), uids); } },
        h("div", { class: "row" }, Object.entries(S.members).filter(([, m]) => m.role !== "viewer").map(([uid]) => h("label", { class: "row" }, h("input", { type: "checkbox", name: "uid", value: uid }), " ", nameOf(uid)))),
        h("div", { class: "row" }, h("select", { name: "stage", "aria-label": "Stage to assign" }, Object.entries(STAGES).map(([k, l]) => h("option", { value: k }, l))), h("button", { type: "submit" }, "Assign")))) : null,
    lead ? h("section", { class: "panel" }, h("h2", {}, "Eligibility criteria"), h("p", { class: "pre" }, S.review.criteria || "Not written yet.")) : null);
}

let searchHits = [];
function memberPicker() {
  if (!S.user || !S.user.search) return h("p", { class: "note" }, "Names are not available in this view.");
  return h("form", { class: "row", onsubmit: (e) => { e.preventDefault(); const f = new FormData(e.target); const uid = String(f.get("uid") || ""); if (uid) addMember(uid, String(f.get("role"))); } },
    h("input", { id: "who", placeholder: "Search people this page is shared with", "aria-label": "Search people", oninput: async (e) => { try { searchHits = await S.user.search(e.target.value); } catch { searchHits = []; } const sel = $("#who-pick"); sel.replaceChildren(...searchHits.map((x) => h("option", { value: x.id }, x.name || "Someone"))); }, onfocus: async () => { try { searchHits = await S.user.search(""); } catch { searchHits = []; } const sel = $("#who-pick"); if (sel) sel.replaceChildren(...searchHits.map((x) => h("option", { value: x.id }, x.name || "Someone"))); } }),
    h("select", { id: "who-pick", name: "uid", "aria-label": "Person" }),
    h("select", { name: "role", "aria-label": "Role" }, h("option", { value: "reviewer" }, "Reviewer"), h("option", { value: "lead" }, "Lead")),
    h("button", { type: "submit" }, "Add to review"),
    S.members[CLAUDE] ? null : h("button", { type: "button", class: "quiet", onclick: () => addMember(CLAUDE, "reviewer") }, "Add Claude (AI) as reviewer"));
}

function importTab() {
  const cands = (S.dedup.candidates || []).map((c, i) => [c, i]).filter(([c]) => c.status === "open");
  const merged = Object.entries(S.pubs).filter(([, p]) => p.mergedInto);
  return h("div", {},
    h("section", { class: "panel" },
      h("h2", {}, "Import references"),
      h("div", { class: "row" }, h("label", { for: "file" }, "RIS, BibTeX or CSV file"), h("input", { id: "file", type: "file", accept: ".ris,.txt,.bib,.bibtex,.csv", onchange: (e) => { const f = e.target.files[0]; if (f) importFile(f); e.target.value = ""; } })),
      S.imports.length ? h("table", {}, h("thead", {}, h("tr", {}, ["File", "Format", "Entries", "Imported", "Warnings", "Failed"].map((x) => h("th", {}, x)))), h("tbody", {}, S.imports.map((b) => h("tr", {}, h("td", {}, b.filename), h("td", {}, b.format), ...[b.entries, b.imported, b.warnings, b.failed].map((n) => h("td", { class: "num" }, String(n))))))) : h("p", { class: "note" }, "No files imported yet."),
      h("p", { class: "note" }, "Every record is kept exactly as it came in the file; the same file cannot be imported twice.")),
    h("section", { class: "panel" },
      h("div", { class: "row spread" }, h("h2", {}, `Possible duplicates (${cands.length})`), h("div", { class: "row" }, h("button", { onclick: findDuplicates }, "Find duplicates"), h("button", { class: "quiet", onclick: autoMerge }, "Merge exact DOI/PMID matches"))),
      cands.length ? h("table", {}, h("thead", {}, h("tr", {}, ["Publication A", "Publication B", "Match", "Check", ""].map((x) => h("th", {}, x)))),
        h("tbody", {}, cands.map(([c, i]) => h("tr", {},
          h("td", {}, (S.pubs[c.a] || {}).title || c.a, h("div", { class: "note" }, `${(S.pubs[c.a] || {}).year || ""} · ${(S.pubs[c.a] || {}).file || ""}`)),
          h("td", {}, (S.pubs[c.b] || {}).title || c.b, h("div", { class: "note" }, `${(S.pubs[c.b] || {}).year || ""} · ${(S.pubs[c.b] || {}).file || ""}`)),
          h("td", {}, { doi: "Same DOI", pmid: "Same PMID", title_year: "Same title, year ±1" }[c.rule]),
          h("td", {}, c.blockers.map((b) => h("span", { class: "tag warn" }, b))),
          h("td", { class: "row" }, h("button", { onclick: () => decideCandidate(i, "merge") }, "Merge"), h("button", { class: "quiet", onclick: () => decideCandidate(i, "reject") }, "Not duplicates")))))) : h("p", { class: "note" }, "No open pairs. Press Find duplicates after each import.")),
    merged.length ? h("section", { class: "panel" }, h("h2", {}, `Merged (${merged.length})`),
      h("table", {}, h("tbody", {}, merged.map(([pid, p]) => h("tr", {}, h("td", {}, p.title), h("td", { class: "note" }, `${p.file} → kept as ${p.mergedInto}`), h("td", {}, h("button", { class: "quiet", onclick: () => unmerge(pid) }, "Undo merge"))))))) : null);
}

function screenTab(st) {
  if (S.stage !== st) { S.stage = st; S.sel = null; }
  const open = !!(S.stages[st] || {}).open;
  const mineAll = Object.entries(S.assign[st] || {}).filter(([, us]) => us.includes(S.uid)).map(([p]) => p).filter((p) => S.pubs[p]).sort();
  const items = mineAll.filter((p) => S.filter === "all" || !myVote(p, st));
  if (!S.sel || !mineAll.includes(S.sel)) S.sel = items[0] || mineAll[0] || null;
  const done = mineAll.filter((p) => myVote(p, st)).length;
  const head = h("div", { class: "row spread" }, h("div", { class: "row" }, h("strong", {}, STAGES[st]), h("span", { class: "note" }, `${done} of ${mineAll.length} decided by you`)),
    h("div", { class: "row seg" }, ["todo", "all"].map((f) => h("button", { class: S.filter === f ? "on" : "quiet", onclick: () => { S.filter = f; render(); } }, f === "todo" ? "Undecided" : "All mine"))));
  if (!mineAll.length) return h("div", {}, head, st === "ft" && isLead() ? fulltextManager() : null, h("section", { class: "panel" }, h("p", {}, st === "ft" ? "Nothing is assigned to you at full text yet. Publications reach this stage when their title/abstract decision is include; a lead then assigns them." : "Nothing is assigned to you at this stage.")));
  const p = S.pubs[S.sel], v = myVote(S.sel, st), team = teamView(S.sel, st), ai = S.myAi[st + "_" + S.sel];
  const notRetrieved = st === "ft" && (S.retrieval[S.sel] || {}).status === "not_retrieved";
  return h("div", {}, head, st === "ft" && isLead() ? fulltextManager() : null,
    open ? h("p", { class: "banner" }, "Reconciliation is open for this stage, so voting is closed. Your votes have been shared with the team.") : null,
    h("div", { class: "screen" },
      h("ul", { class: "queue", "aria-label": "Your publications" }, (items.length ? items : mineAll).map((pid) => {
        const mv = myVote(pid, st);
        return h("li", {}, h("button", { "aria-current": pid === S.sel ? "true" : "false", onclick: () => { S.sel = pid; render(); } }, h("div", {}, S.pubs[pid].title || "(no title)"), h("div", { class: "note" }, `${S.pubs[pid].year || "no year"} · `, mv ? h("span", { class: "d-" + mv.d }, mv.d) : "undecided"))); })),
      h("article", { class: "record" },
        h("h2", {}, p.title || "(no title)"),
        h("p", { class: "note" }, [p.journal, p.year, p.kind, p.doi && "doi:" + p.doi, p.pmid && "PMID " + p.pmid].filter(Boolean).join(" · ")),
        h("div", { class: "abstract" }, p.abstract || "No abstract."),
        st === "ft" ? fulltextBox(S.sel) : null,
        ai ? h("div", { class: "ai" }, h("strong", {}, "Claude's suggestion (not a vote): "), h("span", { class: "d-" + ai.suggestion }, ai.suggestion), ". ", ai.reason || "", ai.quote ? h("div", { class: "note" }, "Supporting text: “", ai.quote, "”", ai.quoteFound ? "" : " — not found word for word in the record; check it.") : null) : null,
        team.revealed ? h("div", { class: "revealed" }, h("h3", {}, "Team decisions"), h("ul", {}, team.votes.map((x) => h("li", {}, nameOf(x.uid), ": ", x.d ? h("span", { class: "d-" + x.d }, x.d) : "no vote", x.first && x.first !== x.d ? ` (first vote: ${x.first})` : "", x.r ? ` — ${x.r}` : ""))), h("p", {}, "Status: ", h("strong", {}, team.status), team.final ? ` · final: ${team.final}` : "")) : h("p", { class: "note" }, "Other reviewers' decisions stay hidden until reconciliation."),
        h("div", { class: "votebar" },
          h("div", { class: "target" }, "Your vote applies to: ", h("em", {}, (p.title || "").slice(0, 100)), v && v.h && v.h.length > 1 ? ` · changed ${v.h.length - 1}×` : ""),
          notRetrieved ? h("p", { class: "note" }, "Full text not retrieved: this is not an exclusion and cannot be screened.") : open ? h("p", { class: "note" }, "Voting is closed.") :
            h("div", { class: "row" },
              DEC.map((d) => h("button", { class: `d-${d}${v && v.d === d ? " chosen" : ""}`, "aria-pressed": v && v.d === d ? "true" : "false", onclick: () => castVote(S.sel, st, d, $("#reason") ? $("#reason").value : "") }, d[0].toUpperCase() + d.slice(1))),
              st === "ft" ? h("select", { id: "reason", "aria-label": "Reason for excluding" }, h("option", { value: "" }, "Reason for excluding (required)"), (S.review.reasonsFt || []).map((r) => h("option", { value: r, selected: v && v.r === r }, r))) : null,
              S.sample ? h("button", { class: "quiet", onclick: () => askClaude(S.sel, st) }, "Ask Claude") : null)))));
}

function fulltextBox(pid) {
  const f = S.fulltext[pid], nr = (S.retrieval[pid] || {}).status === "not_retrieved";
  return h("div", { class: "ft" },
    f ? h("p", {}, h("a", { href: f.url, target: "_blank", rel: "noopener" }, "Open full text (PDF): " + f.name)) : h("p", { class: "note" }, nr ? "Marked as not retrieved." : "No PDF attached yet."),
    isLead() && S.assets ? h("label", { class: "row" }, f ? "Replace PDF " : "Attach PDF ", h("input", { type: "file", accept: "application/pdf,.pdf", "aria-label": "Attach PDF", onchange: (e) => { const x = e.target.files[0]; if (x) attachPdf(pid, x); e.target.value = ""; } })) : null);
}
function fulltextManager() {
  const el = eligible("ft");
  if (!el.length) return null;
  return h("section", { class: "panel" }, h("h2", {}, `Full texts to retrieve (${el.length})`),
    h("table", {}, h("thead", {}, h("tr", {}, ["Publication", "PDF", "Not retrieved"].map((x) => h("th", {}, x)))), h("tbody", {}, el.map((pid) => h("tr", {}, h("td", {}, S.pubs[pid].title), h("td", {}, fulltextBox(pid)),
      h("td", {}, h("input", { type: "checkbox", "aria-label": "Not retrieved", checked: (S.retrieval[pid] || {}).status === "not_retrieved", onchange: (e) => setRetrieval(pid, e.target.checked ? "not_retrieved" : "retrieved") })))))),
    h("p", { class: "note" }, "A report you could not obtain counts as not retrieved in PRISMA, never as excluded."));
}
async function attachPdf(pid, file) {
  if (file.size > 20 * 1024 * 1024) return say("That PDF is over 20 MB, the limit for one file.", true);
  say("Uploading " + file.name + "…");
  try {
    const a = await S.assets.upload(file);
    const ref = S.db.doc(`reviews/${S.rid}/meta/fulltext`);
    await serialWrite(ref.path, async () => { const d = await ref.get(); const map = (d.exists && d.data().map) || {}; map[pid] = { assetId: a.id, url: a.url, name: file.name, bytes: a.sizeBytes, by: S.uid, at: nowIso() }; await ref.set({ map }); });
    await setRetrieval(pid, "retrieved");
    say("PDF attached.");
  } catch (e) { say(e && e.code ? dbErr(e) : "The upload didn't finish. Try again.", true); }
}

function reconcileTab() {
  const st = S.stage, open = !!(S.stages[st] || {}).open, lead = isLead();
  const el = eligible(st), views = el.map((pid) => [pid, teamView(pid, st)]);
  const conflicts = views.filter(([, v]) => v.revealed && v.status === "conflict");
  const waiting = Object.keys(S.members).filter((u) => Object.values(S.assign[st] || {}).some((us) => us.includes(u)) && !((S.released[st] || {})[u] || {}).done);
  const k = kappa(st);
  return h("div", {},
    h("div", { class: "row spread" }, stagePicker(), lead && !open ? h("button", { class: "primary", onclick: () => openReconciliation(st) }, "Open reconciliation (closes voting)") : null),
    !open ? h("section", { class: "panel" }, h("p", {}, "Reconciliation is not open for this stage. When every reviewer has finished, a lead opens it: voting closes and each reviewer's votes are shared."),
      h("p", { class: "note" }, "Check the Progress table on Overview first: votes not cast before reconciliation stay missing.")) :
      h("div", {},
        waiting.length ? h("p", { class: "banner" }, `Waiting for ${waiting.map(nameOf).join(", ")} to open FishingMeta once, which shares their votes. Their publications stay blinded until then.`) : null,
        h("section", { class: "panel" }, h("h2", {}, `Conflicts (${conflicts.length})`),
          conflicts.length ? conflicts.map(([pid, v]) => h("div", { class: "card" },
            h("h3", {}, S.pubs[pid].title),
            h("ul", {}, v.votes.map((x) => h("li", {}, nameOf(x.uid), ": ", h("span", { class: "d-" + x.d }, x.d || "no vote"), x.r ? ` — ${x.r}` : ""))),
            v.resolution ? h("p", {}, "Resolved: ", h("strong", {}, v.resolution.decision), " — ", v.resolution.note) : lead ? h("form", { class: "row", onsubmit: (e) => { e.preventDefault(); const f = new FormData(e.target); resolve(pid, st, String(f.get("decision")), String(f.get("note")), String(f.get("reason") || "")); } },
              h("select", { name: "decision", "aria-label": "Decision" }, h("option", { value: "include" }, "Include"), h("option", { value: "exclude" }, "Exclude")),
              st === "ft" ? h("select", { name: "reason", "aria-label": "Reason if excluded" }, h("option", { value: "" }, "Reason if excluded"), (S.review.reasonsFt || []).map((r) => h("option", { value: r }, r))) : null,
              h("input", { name: "note", placeholder: "How the disagreement was settled", "aria-label": "Resolution note", size: 40 }), h("button", { type: "submit" }, "Save resolution")) : h("p", { class: "note" }, "A lead resolves this."))) : h("p", { class: "note" }, "No conflicts among the publications revealed so far.")),
        k.length ? h("section", { class: "panel" }, h("h2", {}, "Agreement (first independent votes)"),
          h("table", {}, h("thead", {}, h("tr", {}, ["Pair", "n", "Raw agreement", "Cohen's κ"].map((x) => h("th", {}, x)))), h("tbody", {}, k.map((x) => h("tr", {}, h("td", {}, x.pair.map(nameOf).join(" / ")), h("td", { class: "num" }, String(x.n)), h("td", { class: "num" }, x.po.toFixed(2)), h("td", { class: "num" }, x.kappa == null ? "n/a" : x.kappa.toFixed(2))))))) : null,
        st === "ft" && lead ? h("section", { class: "panel" }, h("h2", {}, "Reports not retrieved"), h("p", { class: "note" }, "Mark a full text you could not obtain. It is reported in PRISMA as not retrieved, never as excluded."),
          h("table", {}, h("tbody", {}, el.map((pid) => h("tr", {}, h("td", {}, S.pubs[pid].title), h("td", {}, h("label", { class: "row" }, h("input", { type: "checkbox", checked: (S.retrieval[pid] || {}).status === "not_retrieved", onchange: (e) => setRetrieval(pid, e.target.checked ? "not_retrieved" : "retrieved") }), " Not retrieved"))))))) : null));
}

function exportTab() {
  const st = S.stage;
  return h("div", {},
    h("section", { class: "panel" }, h("div", { class: "row spread" }, h("h2", {}, "Download"), stagePicker()),
      h("p", { class: "note" }, "Exports follow the same blinding as the screen: other reviewers' votes appear only after reconciliation."),
      h("div", { class: "row" },
        h("button", { onclick: () => download(`fishingmeta-${S.rid}-${st}.csv`, toCsv(exportRows(st))) }, "Decisions (CSV)"),
        h("button", { onclick: () => download(`fishingmeta-${S.rid}-${st}-included-ris.txt`, toRis(st)) }, "Included references (RIS as .txt)"))),
    h("section", { class: "panel" }, h("h2", {}, "Statistics"),
      h("p", {}, "Pooling is done in R (metafor), as in the magnesium vs lidocaine review: extraction is exported as CSV, Claude tests the script, and the analysis runs in your RStudio with the Word export. Ask Claude in a conversation: “Run the meta-analysis for review ", S.review.title, "”.")));
}


// ---------------------------------------------------------------- glossy pie (Frutiger Aero)
const PIE_COLORS = {
  done: ["#9fe9ff", "#1fa6dc"], todo: ["#ffffff", "#cfe6ef"], included: ["#b8f2a6", "#2f9a2a"], excluded: ["#ffc1b8", "#d23b2b"],
  conflict: ["#ffeaa0", "#e0a800"], waiting: ["#e6f3f8", "#9bbccb"], blinded: ["#e9f6fb", "#a9cddc"],
};
let pieN = 0;
function pieSvg(segs, center, sub) {
  const total = segs.reduce((t, x) => t + x.n, 0), id = "pie" + pieN++, R = 70, r = 40, cx = 90, cy = 88;
  const defs = Object.entries(PIE_COLORS).map(([k, [a, b]]) => `<linearGradient id="${id}-${k}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient>`).join("");
  let a0 = -Math.PI / 2, paths = "";
  const arc = (a1, a2) => { const big = a2 - a1 > Math.PI ? 1 : 0, p = (rad, a) => [cx + rad * Math.cos(a), cy + rad * Math.sin(a)].map((v) => v.toFixed(2)).join(" ");
    return `M${p(R, a1)} A${R} ${R} 0 ${big} 1 ${p(R, a2)} L${p(r, a2)} A${r} ${r} 0 ${big} 0 ${p(r, a1)} Z`; };
  for (const sg of segs) {
    if (!sg.n) continue;
    const a1 = a0 + (sg.n / total) * Math.PI * 2;
    paths += sg.n === total ? `<circle cx="${cx}" cy="${cy}" r="${(R + r) / 2}" fill="none" stroke="url(#${id}-${sg.k})" stroke-width="${R - r}"/>` : `<path d="${arc(a0, a1 - 0.0001)}" fill="url(#${id}-${sg.k})" stroke="#fff" stroke-width="1.5"/>`;
    a0 = a1;
  }
  if (!total) paths = `<circle cx="${cx}" cy="${cy}" r="${(R + r) / 2}" fill="none" stroke="url(#${id}-todo)" stroke-width="${R - r}"/>`;
  return `<svg viewBox="0 0 180 180" width="180" height="180" role="img" aria-label="${center} ${sub}"><defs>${defs}
<radialGradient id="${id}-gl" cx="50%" cy="20%" r="70%"><stop offset="0" stop-color="#fff" stop-opacity=".85"/><stop offset=".55" stop-color="#fff" stop-opacity=".15"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<radialGradient id="${id}-bub" cx="40%" cy="30%" r="75%"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#d9f3fd"/></radialGradient>
<filter id="${id}-sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="4" stdDeviation="4" flood-color="#09547f" flood-opacity=".25"/></filter></defs>
<g filter="url(#${id}-sh)">${paths}</g>
<ellipse cx="${cx}" cy="${cy - 34}" rx="54" ry="26" fill="url(#${id}-gl)"/>
<circle cx="${cx}" cy="${cy}" r="${r - 2}" fill="url(#${id}-bub)" stroke="#fff" stroke-width="2"/>
<text x="${cx}" y="${cy + 2}" text-anchor="middle" font-size="20" font-weight="700" fill="#0b3550" font-family="Segoe UI, Helvetica Neue, sans-serif">${center}</text>
<text x="${cx}" y="${cy + 18}" text-anchor="middle" font-size="10" fill="#3d6680" font-family="Segoe UI, Helvetica Neue, sans-serif">${sub}</text></svg>`;
}
function pieCard(title, segs, center, sub) {
  return h("div", { class: "piecard" }, h("h3", {}, title), h("div", { html: pieSvg(segs, center, sub) }),
    h("ul", { class: "legend" }, segs.filter((x) => x.n).map((x) => h("li", {}, h("span", { class: "sw", style: `background:linear-gradient(${PIE_COLORS[x.k][0]},${PIE_COLORS[x.k][1]})` }), `${x.label}: ${x.n}`))));
}
function progressPies() {
  const cards = [];
  for (const st of Object.keys(STAGES)) {
    const amap = S.assign[st] || {}, slots = Object.values(amap).reduce((t, us) => t + us.length, 0);
    if (!slots) continue;
    let cast = 0;
    for (const [uid, m] of Object.entries(S.progress)) { const a = m[S.rid + "_" + st], c = m[S.rid + "_" + st + "_claude"]; if (a && S.members[uid]) cast += a.voted; if (c) cast += c.voted; }
    cast = Math.min(cast, slots);
    const pct = Math.round((100 * cast) / slots);
    cards.push(pieCard(STAGES[st] + ": votes", [{ k: "done", n: cast, label: "Votes cast" }, { k: "todo", n: slots - cast, label: "Votes still to cast" }], pct + "%", "screened"));
    const el = eligible(st).filter((pid) => amap[pid]), c = { included: 0, excluded: 0, conflict: 0, waiting: 0, blinded: 0 };
    for (const pid of el) { const v = teamView(pid, st); if (!v.revealed) c.blinded++; else if (v.final === "include") c.included++; else if (v.final === "exclude") c.excluded++; else if (v.status === "conflict") c.conflict++; else c.waiting++; }
    if (c.blinded < el.length) cards.push(pieCard(STAGES[st] + ": decisions", [{ k: "included", n: c.included, label: "Included" }, { k: "excluded", n: c.excluded, label: "Excluded" }, { k: "conflict", n: c.conflict, label: "Conflict to resolve" }, { k: "waiting", n: c.waiting, label: "Missing a vote" }, { k: "blinded", n: c.blinded, label: "Still blinded" }], String(el.length - c.blinded), "decided of " + el.length));
  }
  return h("section", { class: "panel" }, h("h2", {}, "Screening progress"),
    cards.length ? h("div", { class: "pies" }, cards) : h("p", { class: "note" }, "The charts appear once publications are assigned."),
    h("p", { class: "note" }, "While screening is blinded the charts show only how many votes are cast. Decisions appear after reconciliation."));
}
// ---------------------------------------------------------------- data extraction
function includedStudies() {
  const ftAssigned = Object.keys(S.assign.ft || {}).length > 0;
  return eligible("ft").filter((pid) => (ftAssigned ? teamView(pid, "ft").final === "include" : false));
}
async function saveSetup(setup) {
  const ref = S.db.doc(`reviews/${S.rid}/meta/setup`);
  try { await serialWrite(ref.path, () => ref.set(setup)); say("Extraction form saved."); } catch (e) { say(dbErr(e), true); }
}
function readForm(form) {
  const f = new FormData(form), out = { studyId: String(f.get("studyId") || ""), fields: {}, outcomes: {} };
  for (const k of S.setup.studyFields) out.fields[k] = String(f.get("f_" + k) || "");
  for (const o of S.setup.outcomes) {
    const keys = o.type === "binary" ? ["events", "total"] : ["mean", "sd", "n"];
    const arm = (i) => Object.fromEntries(keys.map((k) => { const v = String(f.get(`${o.id}_${i}_${k}`) || "").trim(); return [k, v === "" ? null : Number(v.replace(",", "."))]; }));
    out.outcomes[o.id] = { a1: arm(1), a2: arm(2), source: String(f.get(o.id + "_source") || ""), notReported: f.get(o.id + "_nr") === "on" };
  }
  return out;
}
async function saveExtraction(pid, form) {
  const data = readForm(form), bad = [];
  for (const o of S.setup.outcomes) for (const a of ["a1", "a2"]) for (const [k, v] of Object.entries(data.outcomes[o.id][a])) if (v != null && !Number.isFinite(v)) bad.push(`${o.name} ${k}`);
  if (bad.length) return say("These are not numbers: " + bad.join(", "), true);
  const ref = S.db.doc(`extraction/${S.rid}_${pid}`), prev = S.extraction[pid];
  const changed = prev && JSON.stringify({ s: prev.studyId, f: prev.fields, o: prev.outcomes }) !== JSON.stringify({ s: data.studyId, f: data.fields, o: data.outcomes });
  try {
    await serialWrite(ref.path, () => ref.set({ rid: S.rid, pid, ...data, ai: S.aiDraft && S.aiDraft.pid === pid ? S.aiDraft.used : (prev && prev.ai) || {},
      enteredBy: S.uid, enteredAt: nowIso(), checkedBy: changed ? null : (prev && prev.checkedBy) || null, checkedAt: changed ? null : (prev && prev.checkedAt) || null,
      history: [...((prev && prev.history) || []).slice(-19), { by: S.uid, at: nowIso(), action: prev ? "edited" : "entered" }] }));
    S.aiDraft = null;
    say(changed && prev && prev.checkedBy ? "Saved. Because values changed, the study needs checking again." : "Saved.");
  } catch (e) { say(dbErr(e), true); }
}
async function checkExtraction(pid) {
  const x = S.extraction[pid];
  if (!x) return;
  if (x.enteredBy === S.uid) return say("The check must be done by someone other than the person who entered the data.", true);
  const ref = S.db.doc(`extraction/${S.rid}_${pid}`);
  try { await serialWrite(ref.path, () => ref.set({ ...x, checkedBy: S.uid, checkedAt: nowIso(), history: [...(x.history || []).slice(-19), { by: S.uid, at: nowIso(), action: "checked" }] })); say("Marked as checked."); }
  catch (e) { say(dbErr(e), true); }
}
async function aiExtract(pid, pasted) {
  if (!S.sample) return;
  const p = S.pubs[pid];
  const outs = S.setup.outcomes.map((o) => `- ${o.id}: ${o.name}${o.timepoint ? " at " + o.timepoint : ""} (${o.type === "binary" ? "events and total per arm" : "mean, SD and n per arm" + (o.unit ? ", unit " + o.unit : "")})`).join("\n");
  const prompt = `Extract outcome data for a meta-analysis. Arm 1 = ${S.setup.arms[0]}, arm 2 = ${S.setup.arms[1]}.\nOutcomes:\n${outs}\n\nSource text:\nTitle: ${p.title}\nAbstract: ${p.abstract || ""}\n${pasted ? "Text pasted from the full text:\n" + pasted : ""}\n\nReply with JSON only: {"outcomes":{"<outcome id>":{"a1":{...numbers},"a2":{...numbers},"quote":"the exact sentence or table row the numbers come from"}}}. Leave out any outcome that the text does not report; never estimate or compute a value that is not written.`;
  say("Asking Claude for suggested values…");
  try {
    const out = await S.sample(prompt, { modelTier: "default" });
    const m = (out.text || "").match(/\{[\s\S]*\}/), j = m ? JSON.parse(m[0]) : null;
    if (!j || !j.outcomes) throw {};
    const hay = (p.title || "") + " " + (p.abstract || "") + " " + (pasted || "");
    const used = {};
    for (const [oid, v] of Object.entries(j.outcomes)) used[oid] = { quote: v.quote || "", quoteFound: !!v.quote && hay.includes(v.quote), fields: { a1: v.a1 || {}, a2: v.a2 || {} } };
    const typed = $("#xform") ? readForm($("#xform")) : null;   // keep what the person already typed
    S.aiDraft = { pid, used, typed };
    render();
    say("Suggested values are filled in and marked. Check each against the source before saving.");
  } catch { say("Claude could not suggest values just now.", true); }
}
function extractTab() {
  const studies = includedStudies(), lead = isLead();
  const setupPanel = lead ? h("section", { class: "panel" }, h("h2", {}, "Extraction form"),
    h("form", { onsubmit: (e) => { e.preventDefault(); const f = new FormData(e.target); const outcomes = String(f.get("outcomes")).split("\n").map((l) => l.trim()).filter(Boolean).map((l, i) => { const [name, type, timepoint, unit] = l.split("|").map((x) => (x || "").trim()); return { id: "o" + (i + 1), name, type: /bin|dic|event/i.test(type) ? "binary" : "continuous", timepoint: timepoint || "", unit: unit || "" }; });
      saveSetup({ ...S.setup, arms: [String(f.get("arm1") || "Intervention"), String(f.get("arm2") || "Control")], studyFields: String(f.get("fields")).split(",").map((x) => x.trim()).filter(Boolean), outcomes }); } },
      h("div", { class: "row" }, h("label", { for: "arm1" }, "Arm 1"), h("input", { id: "arm1", name: "arm1", value: S.setup.arms[0] }), h("label", { for: "arm2" }, "Arm 2"), h("input", { id: "arm2", name: "arm2", value: S.setup.arms[1] })),
      h("label", { for: "fields" }, "Study characteristics, separated by commas"), h("input", { id: "fields", name: "fields", value: S.setup.studyFields.join(", ") }),
      h("label", { for: "outs" }, "Outcomes, one per line: name | binary or continuous | timepoint | unit"),
      h("textarea", { id: "outs", name: "outcomes", rows: 4, placeholder: "Flap necrosis | binary | 30 days\nHeart rate | continuous | 1 min after intubation | beats/min" }, S.setup.outcomes.map((o) => [o.name, o.type, o.timepoint, o.unit].join(" | ")).join("\n")),
      h("button", { type: "submit" }, "Save form"),
      h("p", { class: "note" }, "Write the outcome definitions in the protocol first; this form only records the numbers."))) : null;
  if (!studies.length) return h("div", {}, setupPanel, h("section", { class: "panel" }, h("p", {}, "No included studies yet. Studies appear here once their full-text decision is include.")));
  if (!S.xsel || !studies.includes(S.xsel)) S.xsel = studies[0];
  const saved = S.extraction[S.xsel] || {}, p = S.pubs[S.xsel], draft = S.aiDraft && S.aiDraft.pid === S.xsel ? S.aiDraft.used : {};
  const typed = S.aiDraft && S.aiDraft.pid === S.xsel ? S.aiDraft.typed : null;
  const x = typed ? { ...saved, studyId: typed.studyId, fields: typed.fields, outcomes: typed.outcomes } : saved;
  const chip = (pid) => { const e = S.extraction[pid]; return !e ? h("span", { class: "tag" }, "not started") : e.checkedBy ? h("span", { class: "tag d-include" }, "checked") : h("span", { class: "tag warn" }, "entered, to check"); };
  const val = (oid, arm, k) => { const d = draft[oid] && draft[oid].fields[arm] && draft[oid].fields[arm][k]; if (d != null) return String(d); const v = x.outcomes && x.outcomes[oid] && x.outcomes[oid][arm] && x.outcomes[oid][arm][k]; return v == null ? "" : String(v); };
  return h("div", {}, setupPanel,
    h("div", { class: "screen" },
      h("ul", { class: "queue", "aria-label": "Included studies" }, studies.map((pid) => h("li", {}, h("button", { "aria-current": pid === S.xsel ? "true" : "false", onclick: () => { S.xsel = pid; S.aiDraft = null; render(); } }, h("div", {}, (S.extraction[pid] || {}).studyId || S.pubs[pid].title), h("div", {}, chip(pid)))))),
      h("article", { class: "record" },
        h("h2", {}, p.title), h("p", { class: "note" }, [p.journal, p.year, p.doi && "doi:" + p.doi].filter(Boolean).join(" · ")),
        S.fulltext[S.xsel] ? h("p", {}, h("a", { href: S.fulltext[S.xsel].url, target: "_blank", rel: "noopener" }, "Open full text (PDF)")) : null,
        h("form", { id: "xform", onsubmit: (e) => { e.preventDefault(); saveExtraction(S.xsel, e.target); } },
          h("label", { for: "studyId" }, "Study ID (first author and year)"), h("input", { id: "studyId", name: "studyId", value: x.studyId || "" }),
          S.setup.studyFields.map((k) => [h("label", { for: "f_" + k }, k), h("input", { id: "f_" + k, name: "f_" + k, value: (x.fields || {})[k] || "" })]),
          S.setup.outcomes.length ? S.setup.outcomes.map((o) => {
            const keys = o.type === "binary" ? ["events", "total"] : ["mean", "sd", "n"], d = draft[o.id];
            return h("fieldset", { class: d ? "aidraft" : "" }, h("legend", {}, `${o.name}${o.timepoint ? " · " + o.timepoint : ""}${o.unit ? " (" + o.unit + ")" : ""}`),
              [1, 2].map((i) => h("div", { class: "row" }, h("span", { class: "arm" }, S.setup.arms[i - 1]), keys.map((k) => h("label", { class: "row" }, k + " ", h("input", { name: `${o.id}_${i}_${k}`, value: val(o.id, "a" + i, k), inputmode: "decimal", size: 6 }))))),
              h("label", { class: "row" }, h("input", { type: "checkbox", name: o.id + "_nr", checked: !!(x.outcomes && x.outcomes[o.id] && x.outcomes[o.id].notReported) }), " Not reported by this study"),
              h("label", { for: o.id + "_source" }, "Where in the report (table, page)"), h("input", { id: o.id + "_source", name: o.id + "_source", value: (d && d.quote) || (x.outcomes && x.outcomes[o.id] && x.outcomes[o.id].source) || "" }),
              d ? h("p", { class: "note" }, "Suggested by Claude", d.quoteFound ? " — quote found in the text." : " — quote NOT found word for word; check carefully.") : null);
          }) : h("p", { class: "note" }, "No outcomes defined yet. A lead sets up the extraction form above."),
          h("div", { class: "row", style: "margin-top:10px" }, h("button", { type: "submit", class: "primary" }, "Save"),
            S.extraction[S.xsel] && !S.extraction[S.xsel].checkedBy ? h("button", { type: "button", class: "quiet", onclick: () => checkExtraction(S.xsel) }, "Mark as checked") : null)),
        S.sample && S.setup.outcomes.length ? h("details", { class: "ai" }, h("summary", {}, "Ask Claude to suggest values"),
          h("label", { for: "paste" }, "Paste the results text or table from the PDF (optional; the abstract is always sent)"), h("textarea", { id: "paste", rows: 4, style: "width:100%" }),
          h("button", { type: "button", onclick: () => aiExtract(S.xsel, $("#paste").value) }, "Suggest values"),
          h("p", { class: "note" }, "Suggestions are filled into the form and marked. Nothing is saved until a person checks them and presses Save.")) : null,
        x.enteredBy ? h("p", { class: "note" }, `Entered by ${nameOf(x.enteredBy)}${x.checkedBy ? ", checked by " + nameOf(x.checkedBy) : ""}.`) : null)));
}

// ---------------------------------------------------------------- PRISMA 2020 flow
function prismaCounts() {
  const files = S.imports.map((b) => [b.filename, b.imported]);
  const identified = files.reduce((s, [, n]) => s + n, 0);
  const live = Object.values(S.pubs).filter((p) => !p.mergedInto).length;
  const ta = eligible("ta").map((pid) => teamView(pid, "ta"));
  const taExcluded = ta.filter((v) => v.final === "exclude").length, taPending = ta.filter((v) => !v.final).length;
  const sought = eligible("ft");
  const notRetrieved = sought.filter((pid) => (S.retrieval[pid] || {}).status === "not_retrieved").length;
  const ftViews = sought.filter((pid) => (S.retrieval[pid] || {}).status !== "not_retrieved").map((pid) => [pid, teamView(pid, "ft")]);
  const reasons = {};
  for (const [pid, v] of ftViews) if (v.final === "exclude") { const r = (v.resolution && v.resolution.reason) || ((v.votes.find((x) => x.r) || {}).r) || "Reason not recorded"; reasons[r] = (reasons[r] || 0) + 1; }
  const included = ftViews.filter(([, v]) => v.final === "include").length, ftPending = ftViews.filter(([, v]) => !v.final).length;
  return { files, identified, duplicates: identified - live, screened: live, taExcluded, taPending, sought: sought.length, notRetrieved, assessed: ftViews.length, reasons, ftPending, included };
}
function prismaSvg(c) {
  const W = 760, box = (x, y, w, hgt, lines, strong) => `<g><rect x="${x}" y="${y}" width="${w}" height="${hgt}" rx="10" fill="#ffffff" stroke="${strong ? "#0f7fb3" : "#7fb8d4"}" stroke-width="${strong ? 2 : 1.4}"/>${lines.map((l, i) => `<text x="${x + 12}" y="${y + 22 + i * 18}" font-size="13" fill="#0b3550" font-family="Segoe UI, Helvetica Neue, sans-serif"${i === 0 ? ' font-weight="600"' : ""}>${esc(l)}</text>`).join("")}</g>`;
  const arrow = (x1, y1, x2, y2) => `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="#0f7fb3" stroke-width="1.6" marker-end="url(#a)"/>`;
  const esc = (t) => String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const idLines = ["Records identified", ...c.files.map(([f, n]) => `${f}: n = ${n}`)].slice(0, 7);
  const rs = Object.entries(c.reasons); const exLines = ["Reports excluded: n = " + rs.reduce((s, [, n]) => s + n, 0), ...rs.map(([r, n]) => `${r}: n = ${n}`)].slice(0, 7);
  const hId = 28 + idLines.length * 18, y2 = 40 + hId + 30, y3 = y2 + 70, y4 = y3 + 70, hEx = 28 + exLines.length * 18, y6 = y4 + Math.max(70 + (c.ftPending ? 18 : 0), hEx + 24);
  const H = y6 + 80;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="100%" role="img" aria-label="PRISMA 2020 flow diagram"><defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" fill="#0f7fb3"/></marker></defs>
<rect width="${W}" height="${H}" fill="#f6fcff"/>
<text x="20" y="26" font-size="15" font-weight="700" fill="#0b3550" font-family="Segoe UI, Helvetica Neue, sans-serif">Identification, screening and inclusion</text>
${box(20, 40, 330, hId, idLines, true)}${box(410, 40, 330, 46, [`Duplicate records removed: n = ${c.duplicates}`])}${arrow(350, 63, 410, 63)}
${arrow(185, 40 + hId, 185, y2)}${box(20, y2, 330, 46, [`Records screened: n = ${c.screened}`], true)}${box(410, y2, 330, 46 + (c.taPending ? 18 : 0), [`Records excluded: n = ${c.taExcluded}`, ...(c.taPending ? [`Not yet decided: n = ${c.taPending}`] : [])])}${arrow(350, y2 + 23, 410, y2 + 23)}
${arrow(185, y2 + 46, 185, y3)}${box(20, y3, 330, 46, [`Reports sought for retrieval: n = ${c.sought}`], true)}${box(410, y3, 330, 46, [`Reports not retrieved: n = ${c.notRetrieved}`])}${arrow(350, y3 + 23, 410, y3 + 23)}
${arrow(185, y3 + 46, 185, y4)}${box(20, y4, 330, 46 + (c.ftPending ? 18 : 0), [`Reports assessed for eligibility: n = ${c.assessed}`, ...(c.ftPending ? [`Not yet decided: n = ${c.ftPending}`] : [])], true)}${box(410, y4, 330, hEx, exLines)}${arrow(350, y4 + 23, 410, y4 + 23)}
${arrow(185, y4 + 46 + (c.ftPending ? 18 : 0), 185, y6)}${box(20, y6, 330, 46, [`Studies included in review: n = ${c.included}`], true)}
</svg>`;
}
function prismaTab() {
  const c = prismaCounts(), svg = prismaSvg(c);
  return h("div", {}, h("section", { class: "panel" },
    h("div", { class: "row spread" }, h("h2", {}, "PRISMA 2020 flow diagram"), h("button", { onclick: () => download(`prisma-${S.rid}.svg`, svg) }, "Download SVG")),
    h("div", { class: "prisma", html: svg }),
    h("p", { class: "note" }, "Counts come from this review's data. Screening counts appear only after reconciliation, and undecided records are shown separately. Searches of other sources (registers, citation searching) are not tracked here yet; add them to the final figure.")));
}

// ---------------------------------------------------------------- analysis and manuscript (done by Claude, in R / in a document)
function extractionCsvs() {
  const studies = includedStudies(), bin = [], cont = [];
  for (const pid of studies) {
    const x = S.extraction[pid]; if (!x) continue;
    for (const o of S.setup.outcomes) {
      const v = (x.outcomes || {})[o.id]; if (!v || v.notReported) continue;
      if (![v.a1, v.a2].some((a) => a && Object.values(a).some((n) => n != null))) continue;   // nothing entered for this outcome
      const base = { study: x.studyId || pid, publication_id: pid, outcome: o.name, timepoint: o.timepoint, checked: x.checkedBy ? "yes" : "no", source: v.source || "" };
      if (o.type === "binary") bin.push({ ...base, arm1: S.setup.arms[0], events1: v.a1.events ?? "", total1: v.a1.total ?? "", arm2: S.setup.arms[1], events2: v.a2.events ?? "", total2: v.a2.total ?? "" });
      else cont.push({ ...base, unit: o.unit, arm1: S.setup.arms[0], mean1: v.a1.mean ?? "", sd1: v.a1.sd ?? "", n1: v.a1.n ?? "", arm2: S.setup.arms[1], mean2: v.a2.mean ?? "", sd2: v.a2.sd ?? "", n2: v.a2.n ?? "" });
    }
  }
  return { bin, cont };
}
function readiness() {
  const studies = includedStudies();
  return S.setup.outcomes.map((o) => {
    let k = 0, checked = 0;
    for (const pid of studies) { const x = S.extraction[pid]; const v = x && x.outcomes && x.outcomes[o.id]; if (!v || v.notReported) continue; const keys = o.type === "binary" ? ["events", "total"] : ["mean", "sd", "n"]; if (["a1", "a2"].every((a) => keys.every((kk) => v[a] && v[a][kk] != null))) { k++; if (x.checkedBy) checked++; } }
    return { o, k, checked, plan: k >= 3 ? "Meta-analysis" : "Narrative synthesis (fewer than 3 studies)" };
  });
}
async function request(kind, extra) {
  try { await S.db.doc(`reviews/${S.rid}/requests/${kind}`).set({ status: "requested", by: S.uid, at: nowIso(), ...extra }); }
  catch (e) { say(dbErr(e), true); return false; }
  return true;
}
function copyBox(text) {
  return h("div", { class: "copybox" }, h("p", { class: "pre" }, text),
    h("button", { class: "quiet", onclick: async () => { try { await navigator.clipboard.writeText(text); say("Copied. Paste it into a chat with Claude in your Metanalysis project."); } catch { say("Copy was blocked; select the text and copy it by hand.", true); } } }, "Copy"));
}
function analysisTab() {
  const r = readiness(), req = S.requests.analysis, lead = isLead(), csvs = extractionCsvs();
  const st = S.setup.stats || { model: "REML", hksjBelow: 5, minStudies: 3 };
  const ask = `Realizar análise estatística do FishingMeta — revisão "${S.review.title}" (id ${S.rid}). Leia a extração conferida, rode o script em R/metafor no meu RStudio como na metanálise de magnésio vs lidocaína (${st.model}, HKSJ quando houver menos de ${st.hksjBelow} estudos, pooling só com ${st.minStudies} ou mais), exporte figuras e tabelas para o Word e grave os resultados de volta no FishingMeta.`;
  return h("div", {},
    h("section", { class: "panel" }, h("h2", {}, "Readiness"),
      r.length ? h("table", {}, h("thead", {}, h("tr", {}, ["Outcome", "Studies with complete data", "Checked", "Plan"].map((x) => h("th", {}, x)))), h("tbody", {}, r.map((x) => h("tr", {}, h("td", {}, x.o.name), h("td", { class: "num" }, String(x.k)), h("td", { class: "num" }, String(x.checked)), h("td", {}, x.plan))))) : h("p", { class: "note" }, "Define outcomes in Data extraction first."),
      h("p", { class: "note" }, `Settings from the protocol: random effects (${st.model}); Hartung-Knapp-Sidik-Jonkman when fewer than ${st.hksjBelow} studies; pooled only with ${st.minStudies} or more studies; prediction intervals reported.`)),
    h("section", { class: "panel" }, h("h2", {}, "Statistical analysis"),
      h("p", {}, "The numbers are calculated in R (metafor), not in this page, so that every result can be reproduced and checked. Claude runs it in your RStudio, as in the magnesium vs lidocaine review, and writes the results back here."),
      lead ? h("button", { class: "primary big", onclick: async () => { if (await request("analysis", { settings: st })) say("Request saved. Copy the text below into a chat with Claude."); } }, "Run statistical analysis") : h("p", { class: "note" }, "A lead starts the analysis."),
      req ? h("div", {}, h("p", { class: "note" }, `Requested by ${nameOf(req.by)} on ${req.at.slice(0, 16).replace("T", " ")} · status: ${req.status}`), copyBox(ask)) : null,
      h("div", { class: "row" }, h("button", { class: "quiet", onclick: () => download(`extraction_dichotomous_${S.rid}.csv`, toCsv(csvs.bin)) }, `Dichotomous data (CSV, ${csvs.bin.length} rows)`), h("button", { class: "quiet", onclick: () => download(`extraction_continuous_${S.rid}.csv`, toCsv(csvs.cont)) }, `Continuous data (CSV, ${csvs.cont.length} rows)`))),
    h("section", { class: "panel" }, h("h2", {}, "Results"),
      S.analysis.length ? h("table", {}, h("thead", {}, h("tr", {}, ["Outcome", "k", "Effect (95% CI)", "Prediction interval", "I²", "Method", "Run"].map((x) => h("th", {}, x)))),
        h("tbody", {}, S.analysis.map((a) => h("tr", {}, h("td", {}, a.outcome), h("td", { class: "num" }, String(a.k ?? "")), h("td", {}, a.status === "narrative" ? "Narrative synthesis" : `${a.measure || ""} ${fmt(a.estimate)} (${fmt(a.ci_lb)} to ${fmt(a.ci_ub)})`), h("td", {}, a.pi_lb != null ? `${fmt(a.pi_lb)} to ${fmt(a.pi_ub)}` : ""), h("td", { class: "num" }, a.I2 != null ? Math.round(a.I2) + "%" : ""), h("td", { class: "note" }, a.method || ""), h("td", { class: "note" }, (a.at || "").slice(0, 10)))))) : h("p", { class: "note" }, "No results yet. They appear here after Claude runs the analysis.")));
}
const fmt = (x) => (x == null || x === "" ? "" : Number(x).toFixed(2));
function manuscriptTab() {
  const req = S.requests.manuscript, lead = isLead();
  const ask = `Escrever manuscrito do FishingMeta — revisão "${S.review.title}" (id ${S.rid}). Use o protocolo registrado, o fluxograma PRISMA, as decisões de triagem, a extração conferida e os resultados da análise gravados no FishingMeta. Siga PRISMA 2020 e o estilo dos nossos artigos publicados, e crie o manuscrito como documento.`;
  return h("div", {}, h("section", { class: "panel" }, h("h2", {}, "Manuscript"),
    h("p", {}, "Claude drafts the manuscript as a document you can edit and comment on, from the protocol and from what this review holds: the PRISMA counts, screening decisions, checked extraction and the R results."),
    lead ? h("button", { class: "primary big", onclick: async () => { if (await request("manuscript", {})) say("Request saved. Copy the text below into a chat with Claude."); } }, "Write manuscript") : h("p", { class: "note" }, "A lead starts the manuscript."),
    req ? h("div", {}, h("p", { class: "note" }, `Requested by ${nameOf(req.by)} on ${req.at.slice(0, 16).replace("T", " ")} · status: ${req.status}`), copyBox(ask)) : null,
    S.manuscript && S.manuscript.url ? h("p", {}, "Current draft: ", h("a", { href: S.manuscript.url, target: "_blank", rel: "noopener" }, S.manuscript.title || "Open the manuscript"), h("span", { class: "note" }, " · " + (S.manuscript.at || "").slice(0, 10))) : h("p", { class: "note" }, "No draft yet."),
    h("p", { class: "note" }, "Results and figures must come from the R analysis; the draft never invents numbers.")));
}

// ---------------------------------------------------------------- start
async function start() {
  render();
  const c = window.claude;
  if (!c || !c.use) { render(); return; }
  const [db, user, sample, downloads, assets] = await Promise.all(["db", "user", "sample", "downloads", "assets"].map((n) => c.use(n).catch(() => null)));
  Object.assign(S, { db, user, sample, downloads, assets });
  if (user) { try { S.uid = await user.id(); S.isOwner = !!(await user.isOwner()); S.canEdit = !!(await user.canEdit()); const me = await user.me(); if (me && me.name) S.names[S.uid] = me.name; } catch {} }
  if (!db || !S.uid) { render(); return; }
  subscribeMine();
  db.collection("reviews").onSnapshot((snap) => {
    S.reviews = snap.docs.map((d) => ({ id: d.id, ...d.data() })).sort((a, b) => (a.createdAt || "").localeCompare(b.createdAt || ""));
    if (S.rid) S.review = S.reviews.find((r) => r.id === S.rid) || S.review;
    else { const want = (location.hash || "").slice(1); if (want && S.reviews.some((r) => r.id === want)) return openReview(want); }
    render();
  }, (e) => say(dbErr(e), true));
}
document.addEventListener("focusout", () => setTimeout(() => { if (pendingRender) render(); }, 300));
start();
