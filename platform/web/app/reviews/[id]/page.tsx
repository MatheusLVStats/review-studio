"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { FormEvent, useCallback, useEffect, useState } from "react";
import { call, download } from "@/lib/api";

type Member = { id: number; display_name: string; email: string; role: string };
type Review = { id: number; title: string; my_role: string; blind_mode: boolean; members: Member[];
  stages: Record<string, { reconciliation_open: boolean }>; require_reason_ta_exclude: boolean; require_reason_ft_exclude: boolean };
type Vote = { id: number; user_id: number; decision: string; reason_id: number | null; note: string | null; display_name?: string; first_decision?: string };
type Item = { publication: { id: number; title: string; abstract?: string; year: number | null; doi_norm: string | null; journal: string | null; kind: string };
  stage: string; assigned_to_me: boolean; my_vote: Vote | null; my_vote_changes: number; revealed: boolean; locked: boolean; status: string;
  uncertain?: boolean; final_decision?: string | null; votes?: Vote[]; resolution?: { decision: string; note: string } | null };
type Reason = { id: number; stage: string; label: string };

const TABS = ["Overview", "Import and duplicates", "Screening", "Reconciliation", "Export"] as const;

export default function ReviewPage() {
  const rid = Number(useParams<{ id: string }>().id);
  const [review, setReview] = useState<Review | null>(null);
  const [tab, setTab] = useState<(typeof TABS)[number]>("Overview");
  const [err, setErr] = useState("");
  const load = useCallback(async () => {
    try { setReview(await call<Review>(`/reviews/${rid}`)); } catch (x: any) { setErr(x.message); }
  }, [rid]);
  useEffect(() => { load(); }, [load]);

  if (err) return <main><p className="err">{err}</p><Link href="/">Back to reviews</Link></main>;
  if (!review) return null;
  const canLead = review.my_role === "owner" || review.my_role === "lead";
  const tabs = TABS.filter(t => canLead || (t !== "Import and duplicates" && t !== "Reconciliation"));

  return (
    <>
      <header className="top">
        <span><Link href="/">Reviews</Link> / <strong>{review.title}</strong></span>
        <span className="note">Your role: {review.my_role} · Blinding {review.blind_mode ? "on" : "off"}</span>
      </header>
      <main>
        <nav className="tabs" aria-label="Review sections">
          {tabs.map(t => <button key={t} aria-current={t === tab ? "page" : undefined} onClick={() => setTab(t)}>{t}</button>)}
        </nav>
        {tab === "Overview" && <Overview review={review} reload={load} />}
        {tab === "Import and duplicates" && <ImportTab rid={rid} />}
        {tab === "Screening" && <Screening review={review} />}
        {tab === "Reconciliation" && <Reconciliation review={review} reload={load} />}
        {tab === "Export" && <ExportTab rid={rid} />}
      </main>
    </>
  );
}

function useAction() {
  const [msg, setMsg] = useState("");
  const run = async (f: () => Promise<unknown>, ok?: string) => {
    try { const r = await f(); setMsg(ok ?? ""); return r; } catch (x: any) { setMsg(x.message ?? String(x)); }
  };
  return { msg, run };
}

// ---------------------------------------------------------------- overview
function Overview({ review, reload }: { review: Review; reload: () => void }) {
  const rid = review.id;
  const [progress, setProgress] = useState<any>(null);
  const { msg, run } = useAction();
  useEffect(() => { call(`/reviews/${rid}/progress?stage=ta`).then(setProgress).catch(() => {}); }, [rid]);
  const owner = review.my_role === "owner";

  async function addMember(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.currentTarget));
    await run(() => call(`/reviews/${rid}/members`, { json: f }), "Member added.");
    reload();
  }
  async function assignAll(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const ids = new FormData(e.currentTarget).getAll("uid").map(Number);
    const stage = String(new FormData(e.currentTarget).get("stage"));
    const r: any = await run(() => call(`/reviews/${rid}/assignments`, { json: { stage, user_ids: ids } }));
    if (r) run(async () => r, `${r.assignments_added} assignments added.`);
  }

  return (
    <>
      <section>
        <h2>Title/abstract progress</h2>
        {progress && (
          <table style={{ maxWidth: 560 }}><tbody>
            <tr><th>Your decisions</th><td>{Object.entries(progress.mine).map(([k, v]) => `${k} ${v}`).join(" · ") || "Nothing assigned to you"}</td></tr>
            <tr><th>Team results you may see</th><td>{Object.entries(progress.team_revealed).map(([k, v]) => `${k} ${v}`).join(" · ") || "None yet"}</td></tr>
            <tr><th>Still blinded to you</th><td>{progress.team_not_revealed}</td></tr>
            {progress.per_reviewer_votes_cast && <tr><th>Votes cast</th><td>{progress.per_reviewer_votes_cast.map((p: any) =>
              `${review.members.find(m => m.id === p.user_id)?.display_name}: ${p.voted}/${p.assigned}`).join(" · ")}</td></tr>}
          </tbody></table>
        )}
        <p className="note">Counts that depend on other reviewers' decisions appear only for publications revealed to you.</p>
      </section>
      <section>
        <h2>Members</h2>
        <table><thead><tr><th>Name</th><th>E-mail</th><th>Role</th></tr></thead>
          <tbody>{review.members.map(m => <tr key={m.id}><td>{m.display_name}</td><td>{m.email}</td><td>{m.role}</td></tr>)}</tbody></table>
        {owner && (
          <form onSubmit={addMember} className="row" style={{ marginTop: ".6rem" }}>
            <input name="email" type="email" placeholder="E-mail of a registered user" required size={32} />
            <select name="role" defaultValue="reviewer"><option value="reviewer">Reviewer</option><option value="lead">Lead</option><option value="viewer">Viewer</option></select>
            <button>Add member</button>
          </form>
        )}
      </section>
      {(review.my_role === "owner" || review.my_role === "lead") && (
        <section>
          <h2>Assign publications</h2>
          <form onSubmit={assignAll}>
            <p className="note">Assigns every eligible publication that still has room to the reviewers you tick.</p>
            <div className="row">{review.members.filter(m => m.role !== "viewer").map(m =>
              <label key={m.id} className="row"><input type="checkbox" name="uid" value={m.id} /> {m.display_name}</label>)}</div>
            <div className="row"><select name="stage"><option value="ta">Title/abstract</option><option value="ft">Full text</option></select><button>Assign</button></div>
          </form>
        </section>
      )}
      {owner && (
        <section>
          <h2>Blinding</h2>
          <p>Blinding is <strong>{review.blind_mode ? "on" : "off"}</strong>. While on, no one sees another reviewer's decisions until reconciliation reveals a fully voted publication.</p>
          <button onClick={async () => {
            if (review.blind_mode && !window.confirm("Turn blinding off? Every member will see everyone's decisions, and later votes are flagged as cast after unblinding.")) return;
            await run(() => call(`/reviews/${rid}`, { method: "PATCH", json: { blind_mode: !review.blind_mode } }));
            reload();
          }}>{review.blind_mode ? "Turn blinding off" : "Turn blinding on"}</button>
        </section>
      )}
      {msg && <p role="status">{msg}</p>}
    </>
  );
}

// ---------------------------------------------------------------- import and duplicates
function ImportTab({ rid }: { rid: number }) {
  const [batches, setBatches] = useState<any[]>([]);
  const [cands, setCands] = useState<any[]>([]);
  const [last, setLast] = useState<any>(null);
  const { msg, run } = useAction();
  const load = useCallback(async () => {
    setBatches(await call(`/reviews/${rid}/imports`));
    setCands(await call(`/reviews/${rid}/dedup/candidates?status=open`));
  }, [rid]);
  useEffect(() => { load().catch(() => {}); }, [load]);

  async function upload(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const r = await run(() => call(`/reviews/${rid}/imports`, { form }));
    if (r) setLast(r);
    load();
  }
  return (
    <>
      <section>
        <h2>Import references</h2>
        <form onSubmit={upload} className="row">
          <input type="file" name="file" accept=".ris,.txt,.bib,.bibtex,.csv" required />
          <button className="primary">Import file</button>
        </form>
        {last && <p role="status">{last.filename}: {last.entries_found} entries found, {last.imported} imported, {last.with_warnings} with warnings, {last.failed} failed.
          {last.failures.map((f: any) => <span key={f.position} className="err"> {f.message}.</span>)}</p>}
        <table style={{ marginTop: ".6rem" }}><thead><tr><th>File</th><th>Format</th><th>Entries</th><th>Imported</th><th>Warnings</th><th>Failed</th></tr></thead>
          <tbody>{batches.map(b => <tr key={b.id}><td>{b.filename}</td><td>{b.format}</td><td>{b.n_entries}</td><td>{b.n_ok}</td><td>{b.n_warnings}</td><td>{b.n_failed}</td></tr>)}</tbody></table>
      </section>
      <section>
        <h2>Possible duplicates</h2>
        <div className="row">
          <button onClick={async () => { const r: any = await run(() => call(`/reviews/${rid}/dedup/detect`, { method: "POST" })); if (r) run(async () => r, `${r.new_candidates} new pairs to review.`); load(); }}>Find duplicates</button>
          <button onClick={async () => { const r: any = await run(() => call(`/reviews/${rid}/dedup/auto-merge`, { method: "POST" })); if (r) run(async () => r, `${r.merged.length} exact-identifier pairs merged. Any merge can be undone by splitting.`); load(); }}>Merge exact DOI/PMID matches</button>
        </div>
        <table style={{ marginTop: ".6rem" }}><thead><tr><th>Publication A</th><th>Publication B</th><th>Rule</th><th>Warnings</th><th></th></tr></thead>
          <tbody>{cands.map(c => (
            <tr key={c.id}>
              <td>{c.title_a} ({c.year_a})</td><td>{c.title_b} ({c.year_b})</td><td>{c.rule}</td>
              <td>{c.blockers.map((b: string) => <span key={b} className="tag d-maybe">{b === "different_kind" ? "different publication type: link as same study instead" : b.startsWith("notice") ? "correction or notice" : b}</span>)}</td>
              <td className="row">
                <button onClick={async () => { await run(() => call(`/reviews/${rid}/dedup/candidates/${c.id}/merge`, { method: "POST" }), "Merged."); load(); }}>Merge</button>
                <button onClick={async () => { await run(() => call(`/reviews/${rid}/dedup/candidates/${c.id}/reject`, { method: "POST" }), "Marked as not duplicates."); load(); }}>Not duplicates</button>
              </td>
            </tr>))}</tbody></table>
        {cands.length === 0 && <p className="note">No open pairs.</p>}
      </section>
      {msg && <p role="status">{msg}</p>}
    </>
  );
}

// ---------------------------------------------------------------- screening
function Screening({ review }: { review: Review }) {
  const rid = review.id;
  const [stage, setStage] = useState<"ta" | "ft">("ta");
  const [items, setItems] = useState<Item[]>([]);
  const [sel, setSel] = useState<number | null>(null);
  const [detail, setDetail] = useState<Item | null>(null);
  const [reasons, setReasons] = useState<Reason[]>([]);
  const [reason, setReason] = useState<string>("");
  const [advance, setAdvance] = useState(false);
  const { msg, run } = useAction();

  const load = useCallback(async () => {
    const q = await call<{ items: Item[] }>(`/reviews/${rid}/screening/${stage}`);
    setItems(q.items);
    setReasons((await call<Reason[]>(`/reviews/${rid}/reasons`)).filter(r => r.stage === stage || r.stage === "both"));
    return q.items;
  }, [rid, stage]);
  useEffect(() => { load().then(its => setSel(its[0]?.publication.id ?? null)).catch(() => {}); }, [load]);
  const [refresh, setRefresh] = useState(0);
  useEffect(() => {
    // Ignore a response that arrives after the user has moved to another record, so the vote bar never
    // shows (and votes on) a record other than the one selected.
    let current = true;
    if (sel) call<Item>(`/reviews/${rid}/publications/${sel}?stage=${stage}`).then(d => { if (current) setDetail(d); }).catch(() => {});
    return () => { current = false; };
  }, [rid, sel, stage, refresh]);

  async function castVote(decision: string) {
    if (!detail) return;
    const r = await run(() => call(`/reviews/${rid}/publications/${detail.publication.id}/votes`,
      { json: { stage, decision, reason_id: decision === "exclude" && reason ? Number(reason) : null } }), `Saved: ${decision}.`);
    if (!r) return;
    const its = await load();
    const next = advance ? its.find(i => !i.my_vote && i.publication.id !== detail.publication.id) : undefined;
    if (next) setSel(next.publication.id); else setRefresh(n => n + 1);
  }

  const done = items.filter(i => i.my_vote).length;
  return (
    <>
      <div className="row" style={{ marginBottom: ".8rem" }}>
        <select value={stage} onChange={e => setStage(e.target.value as "ta" | "ft")} aria-label="Stage">
          <option value="ta">Title/abstract</option><option value="ft">Full text</option></select>
        <span className="note">{done} of {items.length} decided by you</span>
        <label className="row"><input type="checkbox" checked={advance} onChange={e => setAdvance(e.target.checked)} /> Go to the next undecided record after voting</label>
      </div>
      {items.length === 0 ? <p className="note">Nothing to screen at this stage.</p> : (
        <div className="screen">
          <ul className="queue" aria-label="Publications">
            {items.map(i => (
              <li key={i.publication.id}><button aria-current={i.publication.id === sel} onClick={() => setSel(i.publication.id)}>
                <div>{i.publication.title}</div>
                <div className="note">{i.publication.year ?? "no year"} · {i.my_vote ? <span className={`d-${i.my_vote.decision}`}>{i.my_vote.decision}</span> : "undecided"}{i.revealed ? ` · ${i.status}` : ""}</div>
              </button></li>))}
          </ul>
          {detail && detail.publication.id === sel && (
            <article className="record">
              <h2>{detail.publication.title}</h2>
              <p className="note">{[detail.publication.journal, detail.publication.year, detail.publication.kind, detail.publication.doi_norm && `doi:${detail.publication.doi_norm}`].filter(Boolean).join(" · ")}</p>
              <div className="abstract">{detail.publication.abstract ?? <em>No abstract.</em>}</div>
              {detail.revealed ? (
                <div style={{ marginTop: "1rem" }}>
                  <h3>Team decisions (revealed)</h3>
                  <ul>{detail.votes?.map(v => <li key={v.id}>{v.display_name}: <span className={`d-${v.decision}`}>{v.decision}</span>{v.first_decision !== v.decision ? ` (first vote: ${v.first_decision})` : ""}</li>)}</ul>
                  <p>Status: <strong>{detail.status}</strong>{detail.final_decision ? ` · final: ${detail.final_decision}` : ""}</p>
                </div>
              ) : <p className="note" style={{ marginTop: "1rem" }}>Other reviewers' decisions are blinded.</p>}
              {detail.assigned_to_me ? (
                <div className="votebar">
                  <div className="target">Your vote applies to: <em>{detail.publication.title.slice(0, 90)}</em>{detail.my_vote_changes > 0 ? ` · you changed this vote ${detail.my_vote_changes}×` : ""}</div>
                  {detail.locked ? <p className="note">Votes are locked: this publication is in reconciliation.</p> : (
                    <div className="row">
                      {(["include", "maybe", "exclude"] as const).map(d => (
                        <button key={d} className={`d-${d} ${detail.my_vote?.decision === d ? "chosen" : ""}`} aria-pressed={detail.my_vote?.decision === d} onClick={() => castVote(d)}>{d[0].toUpperCase() + d.slice(1)}</button>))}
                      <select value={reason} onChange={e => setReason(e.target.value)} aria-label="Reason for excluding">
                        <option value="">Reason for excluding{(stage === "ta" ? review.require_reason_ta_exclude : review.require_reason_ft_exclude) ? " (required)" : ""}</option>
                        {reasons.map(r => <option key={r.id} value={r.id}>{r.label}</option>)}
                      </select>
                    </div>)}
                </div>) : <p className="note">This publication is not assigned to you.</p>}
              {msg && <p role="status">{msg}</p>}
            </article>)}
        </div>)}
    </>
  );
}

// ---------------------------------------------------------------- reconciliation
function Reconciliation({ review, reload }: { review: Review; reload: () => void }) {
  const rid = review.id;
  const [stage, setStage] = useState<"ta" | "ft">("ta");
  const [conflicts, setConflicts] = useState<Item[]>([]);
  const [agreement, setAgreement] = useState<any>(null);
  const { msg, run } = useAction();
  const open = review.stages[stage]?.reconciliation_open;
  const load = useCallback(async () => {
    setConflicts(await call(`/reviews/${rid}/stages/${stage}/conflicts`));
    setAgreement(await call(`/reviews/${rid}/agreement?stage=${stage}`));
  }, [rid, stage]);
  useEffect(() => { load().catch(() => {}); }, [load]);

  async function resolve(e: FormEvent<HTMLFormElement>, pid: number) {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.currentTarget)) as Record<string, string>;
    await run(() => call(`/reviews/${rid}/publications/${pid}/resolutions`, { json: { stage, decision: f.decision, note: f.note } }), "Resolution saved. The reviewers' votes are unchanged.");
    load();
  }
  return (
    <>
      <div className="row">
        <select value={stage} onChange={e => setStage(e.target.value as "ta" | "ft")} aria-label="Stage"><option value="ta">Title/abstract</option><option value="ft">Full text</option></select>
        {!open && <button className="primary" onClick={async () => {
          const r: any = await run(() => call(`/reviews/${rid}/stages/${stage}/reconciliation`, { method: "POST" }));
          if (r) run(async () => r, `${r.revealed_now} publications revealed; ${r.still_blind_pending_votes} stay blinded until all their votes are in.`);
          reload(); load();
        }}>Open reconciliation</button>}
        {open && <span className="note">Reconciliation is open. Publications are revealed once all their assigned votes are in, and their votes are then locked.</span>}
      </div>
      {msg && <p role="status">{msg}</p>}
      <section>
        <h2>Conflicts ({conflicts.length})</h2>
        {conflicts.map(c => (
          <div key={c.publication.id} className="record" style={{ marginBottom: ".8rem" }}>
            <h3>{c.publication.title}</h3>
            <ul>{c.votes?.map(v => <li key={v.id}>{v.display_name}: <span className={`d-${v.decision}`}>{v.decision}</span>{v.note ? ` — ${v.note}` : ""}</li>)}</ul>
            {c.resolution ? <p>Resolved: <strong>{c.resolution.decision}</strong> — {c.resolution.note}</p> : (
              <form className="row" onSubmit={e => resolve(e, c.publication.id)}>
                <select name="decision"><option value="include">Include</option><option value="exclude">Exclude</option></select>
                <input name="note" required placeholder="How the disagreement was settled" size={44} />
                <button>Save resolution</button>
              </form>)}
          </div>))}
        {conflicts.length === 0 && <p className="note">{open ? "No conflicts among revealed publications." : "Open reconciliation to see conflicts."}</p>}
      </section>
      {agreement?.pairs?.length > 0 && (
        <section>
          <h2>Agreement (first independent votes)</h2>
          <table style={{ maxWidth: 560 }}><thead><tr><th>Pair</th><th>n</th><th>Raw agreement</th><th>Cohen's κ</th></tr></thead>
            <tbody>{agreement.pairs.map((p: any) => <tr key={`${p.reviewer_a}-${p.reviewer_b}`}>
              <td>{review.members.find(m => m.id === p.reviewer_a)?.display_name} / {review.members.find(m => m.id === p.reviewer_b)?.display_name}</td>
              <td>{p.n}</td><td>{p.raw_agreement}</td><td>{p.cohen_kappa ?? "n/a"}</td></tr>)}</tbody></table>
        </section>)}
    </>
  );
}

// ---------------------------------------------------------------- export
function ExportTab({ rid }: { rid: number }) {
  const [prisma, setPrisma] = useState<any>(null);
  const { msg, run } = useAction();
  useEffect(() => { call(`/reviews/${rid}/prisma`).then(setPrisma).catch(() => {}); }, [rid]);
  return (
    <>
      <section>
        <h2>Download</h2>
        <p className="note">Exports apply the same blinding as the screen: other reviewers' votes appear only for publications revealed to you.</p>
        <div className="row">
          <button onClick={() => run(() => download(`/reviews/${rid}/export?stage=ta&format=csv`, `review-${rid}-ta.csv`))}>Title/abstract decisions (CSV)</button>
          <button onClick={() => run(() => download(`/reviews/${rid}/export?stage=ft&format=csv`, `review-${rid}-ft.csv`))}>Full-text decisions (CSV)</button>
          <button onClick={() => run(() => download(`/reviews/${rid}/export?stage=ta&format=ris`, `review-${rid}-ta-included.ris`))}>Included after title/abstract (RIS)</button>
        </div>
        {msg && <p className="err">{msg}</p>}
      </section>
      {prisma && (
        <section>
          <h2>PRISMA counts</h2>
          <table style={{ maxWidth: 560 }}><tbody>
            <tr><th>Records identified</th><td>{prisma.records_identified} ({prisma.records_identified_by_file.map((f: any) => `${f.filename}: ${f.records}`).join("; ")})</td></tr>
            <tr><th>Duplicates removed</th><td>{prisma.duplicates_removed}</td></tr>
            <tr><th>Publications screened</th><td>{prisma.publications_after_duplicates}</td></tr>
            <tr><th>Title/abstract (revealed to you)</th><td>{Object.entries(prisma.ta).map(([k, v]) => `${k} ${v}`).join(" · ")}</td></tr>
            <tr><th>Full text (revealed to you)</th><td>{Object.entries(prisma.ft).map(([k, v]) => `${k} ${v}`).join(" · ")}</td></tr>
            <tr><th>Reports not retrieved</th><td>{prisma.ft_not_retrieved}</td></tr>
            <tr><th>Studies</th><td>{prisma.studies}</td></tr>
          </tbody></table>
        </section>)}
    </>
  );
}
