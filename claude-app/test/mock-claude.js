/* Test double for window.claude.use on a local server. Shared state lives in localStorage so two
 * browser pages of the same origin act as two viewers. The rules mirror the declaration we publish:
 *   ""                    read view,  write admin
 *   data/users/{self}     private to its owner (nobody else reads or writes)
 *   progress, released    read view,  write self (each person only their own subtree)
 * Viewer comes from ?as=<name>; "lead" is the artifact owner (admin), others are Contributors. */
(function () {
  const as = new URLSearchParams(location.search).get("as") || "lead";
  // Individual plans have no Contributor level: reviewers are Editors (admin), as on Matheus's account.
  const LEVEL = { lead: "owner", ana: "admin", bruno: "admin", viewer: "view" }[as] || "admin";
  const NAMES = { lead: "Lead", ana: "Ana", bruno: "Bruno", viewer: "Viewer" };
  const uid = "u-" + as;
  const PFX = "fm:";   // one localStorage key per document, so two pages never overwrite each other's writes
  const load = () => { const o = {}; for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith(PFX)) o[k.slice(PFX.length)] = JSON.parse(localStorage.getItem(k)); } return o; };
  const put = (path, v) => (v === undefined ? localStorage.removeItem(PFX + path) : localStorage.setItem(PFX + path, JSON.stringify(v)));
  const rank = { view: 0, interact: 1, admin: 2, owner: 3 };
  window.__denied = [];

  function canRead(path) {
    const seg = path.split("/");
    if (seg[0] === "data" && seg[1] === "users") return seg[2] === uid;
    return true;
  }
  function canWrite(path) {
    const seg = path.split("/");
    if (seg[0] === "data" && seg[1] === "users") return seg[2] === uid && rank[LEVEL] >= 1;
    if (seg[0] === "progress" || seg[0] === "released") return seg[1] === uid && rank[LEVEL] >= 1;
    if (seg[0] === "extraction") return rank[LEVEL] >= 1;
    return rank[LEVEL] >= 2;
  }
  const err = (code, message) => Object.assign(new Error(message), { code, message });
  const listeners = new Set();
  function notify() { for (const l of listeners) l(); }
  window.addEventListener("storage", (e) => { if (!e.key || e.key.startsWith(PFX)) notify(); });

  const freeze = (x) => JSON.parse(JSON.stringify(x));
  function snapDoc(path, store) {
    const ok = canRead(path) && store[path] !== undefined;
    return { id: path.split("/").pop(), exists: ok, data: () => (ok ? freeze(store[path]) : undefined), metadata: { fromCache: false, hasPendingWrites: false } };
  }
  function docRef(path) {
    if (path.split("/").length % 2) throw new TypeError("document path needs an even number of segments: " + path);
    return {
      id: path.split("/").pop(), path,
      async get() { return snapDoc(path, load()); },
      async set(data) { if (!canWrite(path)) { window.__denied.push(path); throw err("invalid_argument", "denied"); } put(path, freeze(data)); setTimeout(notify, 0); },
      async update(data) { const s = load(); if (s[path] === undefined) throw err("invalid_argument", "missing"); return this.set({ ...s[path], ...data }); },
      async delete() { if (!canWrite(path)) throw err("invalid_argument", "denied"); put(path, undefined); setTimeout(notify, 0); },
      onSnapshot(next) { const f = () => next(snapDoc(path, load())); listeners.add(f); setTimeout(f, 0); return () => listeners.delete(f); },
      collection(sub) { return collRef(path + "/" + sub); },
    };
  }
  function collRef(path, filters = [], order = null) {
    if (path.split("/").length % 2 === 0) throw new TypeError("collection path needs an odd number of segments: " + path);
    const run = () => {
      const s = load(), depth = path.split("/").length + 1;
      let docs = Object.keys(s).filter((k) => k.startsWith(path + "/") && k.split("/").length === depth && canRead(k)).sort().map((k) => snapDoc(k, s));
      for (const [f, op, v] of filters) docs = docs.filter((d) => (op === "==" ? d.data()[f] === v : true));
      if (order) docs.sort((a, b) => String(a.data()[order] ?? "").localeCompare(String(b.data()[order] ?? "")));
      return { docs, size: docs.length, empty: !docs.length, docChanges: () => [], metadata: { fromCache: false, hasPendingWrites: false } };
    };
    return {
      path,
      doc(id) { return docRef(path + "/" + (id || Math.random().toString(36).slice(2, 12))); },
      async add(data) { const r = this.doc(); await r.set(data); return r; },
      where(f, op, v) { return collRef(path, [...filters, [f, op, v]], order); },
      orderBy(f) { return collRef(path, filters, f); },
      limit() { return this; },
      async get() { return run(); },
      onSnapshot(next) { const f = () => next(run()); listeners.add(f); setTimeout(f, 0); return () => listeners.delete(f); },
    };
  }
  const db = { doc: docRef, collection: (p) => collRef(p) };
  const user = {
    id: async () => uid, me: async () => ({ id: uid, name: NAMES[as] }),
    isOwner: () => as === "lead", canEdit: () => rank[LEVEL] >= 2, can: () => rank[LEVEL] >= 1,
    profiles: async (ids) => Object.fromEntries(ids.map((i) => [i, { name: NAMES[i.slice(2)] || "" }])),
    search: async (q) => Object.keys(NAMES).filter((n) => n !== "viewer").map((n) => ({ id: "u-" + n, name: NAMES[n] })).filter((x) => x.name.toLowerCase().includes((q || "").toLowerCase())),
  };
  const sample = async (prompt) => prompt.includes("Extract outcome")
    ? ({ text: '{"outcomes":{"o1":{"a1":{"mean":2.1,"sd":1.0,"n":30},"a2":{"mean":3.4,"sd":1.2,"n":31},"quote":"pain score"}}}', truncated: false })
    : ({ text: '{"suggestion":"maybe","reason":"The abstract does not state the comparator.","quote":"SYNTHETIC record for testing only"}', truncated: false });
  const assets = rank[LEVEL] >= 2 ? { upload: async (blob) => ({ id: "asset-" + Math.random().toString(36).slice(2, 8), url: URL.createObjectURL(blob), sizeBytes: blob.size, contentType: "application/pdf" }) } : null;
  window.__downloads = [];
  const downloads = { save: async ({ filename, data }) => { window.__downloads.push({ filename, data: String(data) }); return { status: "saved" }; } };
  const caps = { db, user, sample, downloads, assets };
  window.claude = { use: (n) => Promise.resolve(caps[n] || null) };
})();
