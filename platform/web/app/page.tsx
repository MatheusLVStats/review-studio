"use client";

import Link from "next/link";
import { FormEvent, useEffect, useState } from "react";
import { call, setToken } from "@/lib/api";
import { Brand } from "@/app/brand";

type Me = { id: number; email: string; display_name: string };
type ReviewRow = { id: number; title: string; role: string; blind_mode: boolean; publications: number };

export default function Home() {
  const [me, setMe] = useState<Me | null>(null);
  const [checked, setChecked] = useState(false);
  const [reviews, setReviews] = useState<ReviewRow[]>([]);
  const [err, setErr] = useState("");

  async function load() {
    try {
      setMe(await call<Me>("/me"));
      setReviews(await call<ReviewRow[]>("/reviews"));
    } catch { setMe(null); }
    setChecked(true);
  }
  useEffect(() => { load(); }, []);

  if (!checked) return null;
  if (!me) return <SignIn onDone={load} />;

  async function create(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;  // read before any await: React clears currentTarget afterwards
    const f = new FormData(form);
    try {
      await call("/reviews", { json: { title: f.get("title"), description: f.get("description") || null } });
      form.reset();
      load();
    } catch (x: any) { setErr(x.message); }
  }

  return (
    <>
      <header className="top">
        <Brand />
        <span className="row">{me.display_name}
          <button className="quiet" onClick={async () => { await call("/auth/logout", { method: "POST" }); setToken(null); load(); }}>Sign out</button>
        </span>
      </header>
      <main>
        <h1>Your reviews</h1>
        {reviews.length === 0 ? <p className="note">You are not a member of any review yet. Create one below, or ask an owner to add you.</p> : (
          <table>
            <thead><tr><th>Title</th><th>Your role</th><th>Publications</th><th>Blinding</th></tr></thead>
            <tbody>{reviews.map(r => (
              <tr key={r.id}><td><Link href={`/reviews/${r.id}`}>{r.title}</Link></td><td>{r.role}</td><td>{r.publications}</td><td>{r.blind_mode ? "On" : "Off"}</td></tr>
            ))}</tbody>
          </table>
        )}
        <section>
          <h2>Create a review</h2>
          <form onSubmit={create}>
            <label><span>Title</span><input name="title" required size={60} /></label>
            <label><span>Description (optional)</span><textarea name="description" rows={2} cols={60} /></label>
            <button className="primary">Create review</button> {err && <span className="err">{err}</span>}
          </form>
        </section>
      </main>
    </>
  );
}

function SignIn({ onDone }: { onDone: () => void }) {
  const [mode, setMode] = useState<"login" | "register">("login");
  const [err, setErr] = useState("");
  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.currentTarget)) as Record<string, string>;
    try {
      if (mode === "register") await call("/auth/register", { json: f });
      const r = await call<{ token: string }>("/auth/login", { json: { email: f.email, password: f.password } });
      setToken(r.token);
      onDone();
    } catch (x: any) { setErr(x.message); }
  }
  return (
    <main className="welcome">
      <img src="/fishingmeta.svg" alt="" />
      <span className="name">FishingMeta</span>
      <p className="note">Systematic reviews and meta-analyses for your team</p>
      <section>
      <h1>{mode === "login" ? "Sign in" : "Create an account"}</h1>
      <form onSubmit={submit}>
        {mode === "register" && <label><span>Name shown to your team</span><input name="display_name" required /></label>}
        <label><span>E-mail</span><input name="email" type="email" required autoComplete="email" /></label>
        <label><span>Password (at least 10 characters)</span><input name="password" type="password" required minLength={10}
          autoComplete={mode === "login" ? "current-password" : "new-password"} /></label>
        <button className="primary">{mode === "login" ? "Sign in" : "Create account"}</button>
        {err && <p className="err">{err}</p>}
      </form>
      </section>
      <p className="note">
        {mode === "login" ? "No account yet? " : "Already have an account? "}
        <button className="quiet" onClick={() => { setErr(""); setMode(mode === "login" ? "register" : "login"); }}>
          {mode === "login" ? "Create an account" : "Sign in"}
        </button>
      </p>
    </main>
  );
}
