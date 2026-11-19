"""Parsers for RIS, BibTeX and CSV reference files.

Each parser returns (entries, failures). An entry is a dict with:
  raw_text  - the exact text of the entry as it appeared in the file
  fields    - parsed fields (lists for repeatable tags)
  norm      - normalised values used to build a publication
  warnings  - list of plain-language warnings
A failure is {"position": n, "message": "..."}; nothing is dropped silently.
"""
from __future__ import annotations

import csv
import io
import re

DOI_PREFIX = re.compile(r"^(https?://(dx\.)?doi\.org/|doi:\s*)", re.I)
YEAR = re.compile(r"(1[5-9]\d\d|20\d\d|21\d\d)")


def norm_doi(value: str | None) -> str | None:
    if not value:
        return None
    v = DOI_PREFIX.sub("", value.strip()).strip().lower()
    return v or None


def norm_year(value: str | None) -> int | None:
    if not value:
        return None
    m = YEAR.search(str(value))
    return int(m.group(1)) if m else None


def strip_braces(value: str | None) -> str | None:
    if value is None:
        return None
    return re.sub(r"\s+", " ", value.replace("{", "").replace("}", "")).strip()


def norm_title(value: str | None) -> str:
    """Matching key: lower case, letters and digits only, single spaces."""
    v = (strip_braces(value) or "").lower()
    v = re.sub(r"[^0-9a-z]+", " ", v)
    return re.sub(r"\s+", " ", v).strip()


def _finish(fields: dict, title, abstract, authors, year_raw, journal, doi, pmid, kind) -> dict:
    warnings = []
    title = strip_braces(title)
    if not title:
        warnings.append("No title")
    year = norm_year(year_raw)
    if year_raw and year is None:
        warnings.append(f"Year not understood: {year_raw!r}")
    if not year_raw:
        warnings.append("No year")
    return {
        "fields": fields,
        "norm": {
            "title": title,
            "abstract": strip_braces(abstract),
            "authors": [strip_braces(a) for a in authors if a and a.strip()],
            "year": year,
            "journal": strip_braces(journal),
            "doi_norm": norm_doi(doi),
            "pmid": pmid.strip() if pmid and pmid.strip() else None,
            "kind": kind,
        },
        "warnings": warnings,
    }


# ---------------------------------------------------------------- RIS
RIS_LINE = re.compile(r"^([A-Z][A-Z0-9])  -( (.*))?$")
RIS_KIND = {"JOUR": "journal", "JFULL": "journal", "ABST": "conference", "CONF": "conference",
            "CPAPER": "conference", "DBASE": "registry", "CTRIAL": "registry"}


def parse_ris(text: str):
    entries, failures = [], []
    cur, raw, last, start = None, [], None, 0
    lines = text.splitlines()
    for n, line in enumerate(lines, 1):
        m = RIS_LINE.match(line.rstrip("\r"))
        if m:
            tag, val = m.group(1), (m.group(3) or "").strip()
            if tag == "TY":
                if cur is not None:
                    failures.append({"position": start, "message": f"Entry starting at line {start} has no ER line"})
                cur, raw, start = {}, [line], n
                cur.setdefault("TY", []).append(val)
                last = "TY"
                continue
            if cur is None:
                failures.append({"position": n, "message": f"Line {n} is outside any entry (no TY before it)"})
                continue
            raw.append(line)
            if tag == "ER":
                entries.append(_ris_entry(cur, "\n".join(raw)))
                cur, raw, last = None, [], None
                continue
            cur.setdefault(tag, []).append(val)
            last = tag
        elif cur is not None:
            raw.append(line)
            if line.strip() and last:  # continuation line
                cur[last][-1] = (cur[last][-1] + " " + line.strip()).strip()
    if cur is not None:
        failures.append({"position": start, "message": f"Entry starting at line {start} has no ER line"})
    return entries, failures


def _ris_entry(f: dict, raw: str) -> dict:
    g = lambda *tags: next((f[t][0] for t in tags if f.get(t)), None)  # noqa: E731
    authors = f.get("AU", []) + f.get("A1", [])
    an = g("AN")
    db = (g("DB") or "").lower()
    pmid = an if an and an.isdigit() and ("pubmed" in db or "medline" in db) else None
    kind = RIS_KIND.get((g("TY") or "").upper(), "other")
    e = _finish(f, g("TI", "T1"), g("AB", "N2"), authors, g("PY", "Y1", "DA"), g("T2", "JO", "JF", "JA"),
                g("DO"), pmid, kind)
    e["raw_text"] = raw
    return e


# ---------------------------------------------------------------- BibTeX
def parse_bibtex(text: str):
    entries, failures = [], []
    i, n = 0, len(text)
    while True:
        at = text.find("@", i)
        if at < 0:
            break
        m = re.match(r"@\s*([A-Za-z]+)\s*([{(])", text[at:])
        if not m:
            i = at + 1
            continue
        etype = m.group(1).lower()
        if etype in ("comment", "preamble", "string"):
            i = at + m.end()
            continue
        open_ch = m.group(2)
        close_ch = "}" if open_ch == "{" else ")"
        j, depth = at + m.end(), 1
        while j < n and depth:
            c = text[j]
            if c == open_ch or (open_ch == "{" and c == "{"):
                depth += 1
            elif c == close_ch or (open_ch == "{" and c == "}"):
                depth -= 1
            j += 1
        line_no = text.count("\n", 0, at) + 1
        if depth:
            failures.append({"position": line_no, "message": f"Entry at line {line_no} has unbalanced braces"})
            break
        raw = text[at:j]
        body = text[at + m.end(): j - 1]
        try:
            entries.append(_bib_entry(etype, body, raw))
        except ValueError as exc:
            failures.append({"position": line_no, "message": f"Entry at line {line_no}: {exc}"})
        i = j
    return entries, failures


def _bib_fields(body: str) -> tuple[str, dict]:
    key, _, rest = body.partition(",")
    fields, k = {}, 0
    while k < len(rest):
        m = re.match(r"\s*([A-Za-z][\w\-]*)\s*=\s*", rest[k:])
        if not m:
            if rest[k:].strip(" \t\r\n,"):
                raise ValueError("field list could not be read")
            break
        name = m.group(1).lower()
        k += m.end()
        if k < len(rest) and rest[k] == "{":
            depth, s = 1, k + 1
            k += 1
            while k < len(rest) and depth:
                depth += {"{": 1, "}": -1}.get(rest[k], 0)
                k += 1
            if depth:
                raise ValueError(f"unbalanced braces in field {name}")
            val = rest[s:k - 1]
        elif k < len(rest) and rest[k] == '"':
            e = rest.index('"', k + 1)
            val, k = rest[k + 1:e], e + 1
        else:
            mm = re.match(r"[^,]*", rest[k:])
            val = mm.group(0).strip()
            k += mm.end()
        fields[name] = re.sub(r"\s+", " ", val).strip()
        mm = re.match(r"\s*,?", rest[k:])
        k += mm.end()
    return key.strip(), fields


def _bib_entry(etype: str, body: str, raw: str) -> dict:
    key, f = _bib_fields(body)
    authors = [a.strip() for a in re.split(r"\s+and\s+", f.get("author", "")) if a.strip()]
    kind = {"article": "journal", "inproceedings": "conference", "conference": "conference"}.get(etype, "other")
    pmid = f.get("pmid")
    e = _finish({"_type": etype, "_key": key, **f}, f.get("title"), f.get("abstract"), authors, f.get("year"),
                f.get("journal") or f.get("booktitle"), f.get("doi"), pmid, kind)
    e["raw_text"] = raw
    return e


# ---------------------------------------------------------------- CSV
CSV_KIND = {"journal": "journal", "article": "journal", "conference": "conference", "abstract": "conference",
            "registry": "registry", "trial": "registry"}


def parse_csv(text: str):
    entries, failures = [], []
    reader = csv.reader(io.StringIO(text))
    try:
        header = next(reader)
    except StopIteration:
        return [], [{"position": 1, "message": "The file is empty"}]
    cols = [h.strip().lower() for h in header]
    if "title" not in cols:
        return [], [{"position": 1, "message": "No 'title' column in the header row"}]
    for n, row in enumerate(reader, 2):
        if not any(c.strip() for c in row):
            continue
        if len(row) != len(cols):
            failures.append({"position": n, "message": f"Row {n} has {len(row)} columns; the header has {len(cols)}"})
            continue
        f = dict(zip(cols, row))
        buf = io.StringIO()
        csv.writer(buf, lineterminator="").writerow(row)
        authors = [a.strip() for a in re.split(r";", f.get("authors", "")) if a.strip()]
        kind = CSV_KIND.get((f.get("type") or "journal").strip().lower(), "other")
        e = _finish(f, f.get("title"), f.get("abstract"), authors, f.get("year"), f.get("journal"),
                    f.get("doi"), f.get("pmid"), kind)
        e["raw_text"] = buf.getvalue()
        entries.append(e)
    return entries, failures


def detect_format(filename: str) -> str | None:
    name = filename.lower()
    if name.endswith((".ris", ".txt")):
        return "ris"
    if name.endswith((".bib", ".bibtex")):
        return "bibtex"
    if name.endswith(".csv"):
        return "csv"
    return None


PARSERS = {"ris": parse_ris, "bibtex": parse_bibtex, "csv": parse_csv}
