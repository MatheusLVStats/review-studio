// Run: node --experimental-strip-types tests/ris.test.mjs   (synthetic records only)
import { parseRis } from "../supabase/functions/mcp/ris.ts";
import assert from "node:assert/strict";
const pubmed = `﻿TY  - JOUR\r\nAU  - Silva, A\r\nAU  - Costa, B\r\nTI  - Synthetic alpha trial of a long\r\n      wrapped title\r\nPY  - 2020/03/01\r\nT2  - Synthetic Journal\r\nVL  - 12\r\nSP  - 10\r\nEP  - 19\r\nDO  - https://doi.org/10.1000/A1.\r\nAN  - 12345678\r\nDP  - NLM\r\nDB  - PubMed\r\nAB  - Synthetic abstract.\r\nER  - \r\n\r\nTY  - JOUR\r\nTI  - Second synthetic\r\nPY  - 2019\r\nAN  - 22345678\r\nDB  - PubMed\r\nER  - \r\n`;
let r = parseRis(pubmed, "export.ris");
assert.equal(r.rows.length, 2);
assert.equal(r.rows[0].parsed.title, "Synthetic alpha trial of a long wrapped title");
assert.deepEqual(r.rows[0].parsed.authors, ["Silva, A", "Costa, B"]);
assert.equal(r.rows[0].parsed.year, "2020");
assert.equal(r.rows[0].parsed.doi, "10.1000/A1");
assert.equal(r.rows[0].parsed.pmid, "12345678");
assert.equal(r.rows[0].parsed.pages, "10-19");
assert.equal(r.suggestion.preset, "pubmed");
assert.equal(r.suggestion.mixed, false);
// Embase accession is not a PMID; file name agrees with field
const embase = `TY  - JOUR\nT1  - Synthetic embase record\nA1  - Lima, C\nY1  - 2018\nAN  - L2012345678\nDB  - Embase\nN2  - Abstract here\nER  - \n`;
r = parseRis(embase, "embase_2026-11-01.ris");
assert.equal(r.rows[0].parsed.pmid, null);
assert.equal(r.rows[0].parsed.src_record_id, "L2012345678");
assert.equal(r.rows[0].parsed.abstract, "Abstract here");
assert.equal(r.suggestion.preset, "embase");
// Cochrane PM field
const central = `Record #1 of 1\nProvider: John Wiley & Sons, Ltd\nTY  - JOUR\nTI  - Synthetic central\nID  - CN-01234567\nPM  - PUBMED 32345678\nPY  - 2021\nER  - \n`;
r = parseRis(central, "citation-export.ris");
assert.equal(r.rows[0].parsed.pmid, "32345678");
assert.equal(r.rows[0].parsed.src_record_id, "CN-01234567");
assert.equal(r.exporting_software, "Cochrane Library export");
assert.equal(r.suggestion.preset, "central"); // from header only
// generic file: unknown origin; filename is only a suggestion
r = parseRis(`TY  - JOUR\nTI  - No database field\nPY  - 2020\nER  - \n`, "My Library.ris");
assert.equal(r.suggestion.preset, null);
r = parseRis(`TY  - JOUR\nTI  - No database field\nPY  - 2020\nER  - \n`, "scopus.ris");
assert.equal(r.suggestion.preset, "scopus");
// mixed sources and filename disagreement -> no suggestion
r = parseRis(pubmed.replace("﻿","") + embase, "all.ris");
assert.equal(r.suggestion.preset, null); assert.equal(r.suggestion.mixed, true);
r = parseRis(embase, "pubmed.ris");
assert.equal(r.suggestion.preset, null); assert.equal(r.suggestion.mixed, true);
// truncated file and empty record are rejected, not guessed
r = parseRis(`TY  - JOUR\nPY  - 2020\nER  - \nTY  - JOUR\nTI  - Cut off record\nAB  - text that stops`, "x.ris");
assert.equal(r.rows[0].status, "rejected"); assert.match(r.rows[0].reject_reason, /No title/);
assert.equal(r.rows[1].status, "rejected"); assert.match(r.rows[1].reject_reason, /no end marker/);
// not RIS at all
r = parseRis("Title,Year\nA,2020\n", "x.csv");
assert.equal(r.rows.length, 0); assert.ok(r.warnings.some(w => /No RIS records/.test(w)));
console.log("ris parser: all assertions passed");
