# Edge Function `mcp`

Deployed version 2 (2026-11-11) is exactly the two files in this folder:

- `index.ts` – MCP server, REST route `/api/call`, 42 tool definitions.
- `ris.ts` – RIS parser (tests in `tests/ris.test.mjs`).

Changes in version 2:

- New tool `propose_dedup_rules`: the person chooses which fields must match exactly and which database's version is kept.
- The content hash that binds a confirmation is no longer written into the conversation text of `propose_*` results. The screen still receives it (structured content), because the person confirms there.

Deploy with `supabase functions deploy mcp --project-ref wiomuxjhozhymxeuaihx --no-verify-jwt` (the function checks the token itself and must answer the unauthenticated OAuth discovery request).
