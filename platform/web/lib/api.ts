// Thin client for the FastAPI server. No review rules live here: the server decides what each user may see.
export const API = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

export type ApiError = { error: string; message: string };

function token(): string | null {
  try { return window.localStorage.getItem("rp_token"); } catch { return null; }
}
export function setToken(t: string | null) {
  try { t ? window.localStorage.setItem("rp_token", t) : window.localStorage.removeItem("rp_token"); } catch { /* storage unavailable */ }
}

export async function call<T = any>(path: string, opts: { method?: string; json?: unknown; form?: FormData } = {}): Promise<T> {
  const headers: Record<string, string> = {};
  const t = token();
  if (t) headers["Authorization"] = `Bearer ${t}`;
  let body: BodyInit | undefined;
  if (opts.json !== undefined) { headers["Content-Type"] = "application/json"; body = JSON.stringify(opts.json); }
  if (opts.form) body = opts.form;
  const r = await fetch(API + path, { method: opts.method ?? (body ? "POST" : "GET"), headers, body });
  if (!r.ok) {
    let e: ApiError = { error: String(r.status), message: r.statusText };
    try { e = await r.json(); } catch { /* not JSON */ }
    throw e;
  }
  const ct = r.headers.get("content-type") ?? "";
  return (ct.includes("application/json") ? r.json() : r.text()) as Promise<T>;
}

export async function download(path: string, filename: string) {
  const text = await call<string>(path);
  const url = URL.createObjectURL(new Blob([text]));
  const a = document.createElement("a");
  a.href = url; a.download = filename; a.click();
  URL.revokeObjectURL(url);
}
