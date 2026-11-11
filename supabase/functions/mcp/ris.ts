// RIS parser for Review Studio. Pure function, no I/O, so it can be tested outside the Edge Function.
// It reports what it could not read instead of guessing.
export const PARSER_VERSION = "ris-0.1.0";

export interface ParsedRow {
  row_no: number;
  status: "accepted" | "rejected";
  reject_reason?: string;
  raw: string;
  parsed: Record<string, unknown>;
}
export interface ParseResult {
  rows: ParsedRow[];
  warnings: string[];
  exporting_software: string | null;
  suggestion: { preset: string | null; evidence: string[]; mixed: boolean };
}

const TAG = /^([A-Z][A-Z0-9])  - ?(.*)$/;

const PRESET_PATTERNS: [string, RegExp][] = [
  ["pubmed", /pubmed|medline|\bnlm\b/i],
  ["embase", /embase/i],
  ["central", /cochrane|central\b/i],
  ["scopus", /scopus/i],
  ["wos", /web of science|\bwos\b|clarivate|savedrecs/i],
  ["lilacs", /lilacs|bvs|bireme/i],
  ["registry", /clinicaltrials\.gov|ictrp|trial regist/i],
];

function presetOf(text: string): string | null {
  for (const [preset, re] of PRESET_PATTERNS) if (re.test(text)) return preset;
  return null;
}

function first(rec: Map<string, string[]>, ...tags: string[]): string | null {
  for (const t of tags) {
    const v = rec.get(t);
    if (v && v.length && v[0].trim()) return v[0].trim();
  }
  return null;
}

function cleanDoi(v: string | null): string | null {
  if (!v) return null;
  const m = v.match(/10\.\d{4,9}\/[^\s"<>]+/);
  return m ? m[0].replace(/[.,;]+$/, "") : null;
}

function toRecord(rec: Map<string, string[]>): Record<string, unknown> {
  const dbText = [...(rec.get("DB") ?? []), ...(rec.get("DP") ?? [])].join(" ");
  const db = presetOf(dbText);
  const an = first(rec, "AN");
  let pmid: string | null = null;
  const pm = first(rec, "PM"); // Cochrane CENTRAL style: "PM  - PUBMED 12345678"
  if (pm && /\d{5,9}/.test(pm)) pmid = pm.match(/\d{5,9}/)![0];
  else if (an && /^\d{5,9}$/.test(an) && db === "pubmed") pmid = an;
  else if (db === "scopus") {
    const c2 = first(rec, "C2");
    if (c2 && /^\d{5,9}$/.test(c2)) pmid = c2;
  }
  const year = (first(rec, "PY", "Y1", "DA") ?? "").match(/(1[89]|20)\d{2}/)?.[0] ?? null;
  const sp = first(rec, "SP"), ep = first(rec, "EP");
  return {
    ref_type: first(rec, "TY"),
    title: first(rec, "TI", "T1", "ST"),
    authors: [...(rec.get("AU") ?? []), ...(rec.get("A1") ?? [])].map((s) => s.trim()).filter(Boolean),
    year,
    journal: first(rec, "T2", "JF", "JO", "J2", "JA"),
    volume: first(rec, "VL"),
    issue: first(rec, "IS"),
    pages: sp ? (ep ? `${sp}-${ep}` : sp) : null,
    doi: cleanDoi(first(rec, "DO") ?? (rec.get("UR") ?? []).find((u) => /doi\.org\//i.test(u)) ?? null),
    pmid,
    abstract: first(rec, "AB", "N2"),
    keywords: (rec.get("KW") ?? []).map((s) => s.trim()).filter(Boolean),
    url: first(rec, "UR", "L2"),
    language: first(rec, "LA"),
    src_record_id: an ?? first(rec, "ID", "U2"),
    database_field: first(rec, "DB"),
    provider_field: first(rec, "DP"),
  };
}

export function parseRis(text: string, filename: string): ParseResult {
  const warnings: string[] = [];
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  if (text.includes("�")) warnings.push("Some characters could not be decoded as UTF-8; accents may be wrong. The original file is kept unchanged.");
  const lines = text.split(/\r\n|\n|\r/);
  const rows: ParsedRow[] = [];
  let cur: Map<string, string[]> | null = null;
  let raw: string[] = [];
  let lastTag: string | null = null;
  let stray = 0;
  const header: string[] = [];

  const finish = (terminated: boolean) => {
    if (!cur) return;
    const parsed = toRecord(cur);
    const row: ParsedRow = { row_no: rows.length + 1, status: "accepted", raw: raw.join("\n"), parsed };
    if (!terminated) {
      row.status = "rejected";
      row.reject_reason = "Record has no end marker (ER). The file may be cut off; nothing was assumed about the missing part.";
    } else if (!parsed.title && !parsed.doi && !parsed.pmid) {
      row.status = "rejected";
      row.reject_reason = "No title and no identifier (DOI or PMID)";
    }
    rows.push(row);
    cur = null; raw = []; lastTag = null;
  };

  for (const line of lines) {
    const m = line.match(TAG);
    if (m) {
      const [, tag, value] = m;
      if (tag === "TY") {
        if (cur) finish(false);
        cur = new Map(); raw = [];
      }
      if (!cur) { if (line.trim()) { stray++; if (header.length < 20) header.push(line); } continue; }
      raw.push(line);
      if (tag === "ER") { finish(true); continue; }
      if (!cur.has(tag)) cur.set(tag, []);
      cur.get(tag)!.push(value);
      lastTag = tag;
    } else if (cur && lastTag && line.trim()) {
      raw.push(line);
      const arr = cur.get(lastTag)!;
      arr[arr.length - 1] += " " + line.trim();
    } else if (!cur && line.trim()) {
      stray++; if (header.length < 20) header.push(line);
    }
  }
  if (cur) finish(false);
  if (stray) warnings.push(`${stray} line(s) outside any record were ignored.`);
  if (!rows.length) warnings.push("No RIS records were found. Check that this is a RIS export (records start with 'TY  - ' and end with 'ER  - ').");

  let software: string | null = null;
  const sample = rows.slice(0, 50).map((r) => r.raw).join("\n");
  if (/^N1  - Export Date:/m.test(sample) && /scopus/i.test(sample)) software = "Scopus export";
  else if (/Record #\d+ of \d+/.test(header.join("\n")) || /^PM  - PUBMED/m.test(sample)) software = "Cochrane Library export";
  else if (/embase\.com/i.test(sample)) software = "Embase.com export";
  else if (/^DP  - (NLM|PubMed)/im.test(sample)) software = "Reference manager export of PubMed records (EndNote/Zotero style)";

  // Origin suggestion: evidence only, never a verified origin.
  const evidence: string[] = [];
  const counts = new Map<string, number>();
  let withField = 0;
  for (const r of rows) {
    const p = presetOf(`${r.parsed.database_field ?? ""} ${r.parsed.provider_field ?? ""}`);
    if (r.parsed.database_field || r.parsed.provider_field) withField++;
    if (p) counts.set(p, (counts.get(p) ?? 0) + 1);
  }
  const fromName = presetOf(filename.replace(/[_\-.]+/g, " "));
  const headerPreset = presetOf(header.join(" "));
  let preset: string | null = null;
  let mixed = false;
  if (counts.size === 1) {
    const [p, n] = [...counts.entries()][0];
    preset = p;
    evidence.push(`Database/provider field points to ${p} in ${n} of ${rows.length} records`);
  } else if (counts.size > 1) {
    mixed = true;
    evidence.push(`Database/provider fields point to several sources: ${[...counts.entries()].map(([p, n]) => `${p} (${n})`).join(", ")}. This looks like a mixed-source file.`);
  } else if (withField === 0 && rows.length) {
    evidence.push("Records carry no database or provider field");
  }
  if (fromName) {
    evidence.push(`File name suggests ${fromName}`);
    if (!preset && !mixed) preset = fromName;
    else if (preset && preset !== fromName) { evidence.push("File name and record fields disagree"); mixed = true; preset = null; }
  }
  if (headerPreset && !preset && !mixed) { preset = headerPreset; evidence.push(`File header mentions ${headerPreset}`); }
  if (software === "Cochrane Library export" && !preset && !mixed) { preset = "central"; evidence.push("Record layout matches a Cochrane Library export"); }

  return { rows, warnings, exporting_software: software, suggestion: { preset, evidence, mixed } };
}
