# Review Studio

Collaborative systematic-review and meta-analysis workspace (first release: screening slice).

- `app.html` – the screen. It runs inside Claude (MCP App) and as a normal web page (browser fallback, sign-in and OAuth consent).
- `supabase/functions/mcp/` – Edge Function: remote MCP server + small REST API + RIS parser.
- `supabase/migrations/` – database (private schema `rs`, API functions `public.rs_*`, self-test `rs.selftest()`).
- `tests/` – parser tests on synthetic records.

No secrets live in this repository. The Supabase publishable key in `app.html` is public by design; all access is decided in the database.
