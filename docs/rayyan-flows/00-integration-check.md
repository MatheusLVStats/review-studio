# 00 — REA integration check

Date: 2026-11-19. Machine: the user's MacBook Air (macOS, arm64). Checked from a Claude session through the Claude desktop app.

## Scope and rules for this investigation

- Observe Rayyan **as a user** in the user's own authorised session: screens, actions, states, messages and exported files.
- Do **not** decompile, recover or copy Rayyan's JavaScript, and do **not** record or document Rayyan's network API. Rayyan's Terms of Service (revised 2023-09-15) prohibit duplicating, decompiling and reverse engineering the service. Our server rules are written in our own specification, not copied from Rayyan responses.
- Use only a test review with the synthetic files in `test-data/synthetic/`. Never open, change or export the user's real reviews.
- Never write credentials, cookies, tokens, e-mail addresses or review IDs of real reviews into these reports.

## Result

| Item | State | Evidence |
|---|---|---|
| REA installed | Yes, `rea-agents` 6.9.0 at `~/.local/lib/node_modules/rea-agents`, Node 26.13.1 | `binary_session` server identity |
| Registered with the Claude desktop app | Yes, local MCP server `rea` state `announced` | `get_device_info.localMcpServers` |
| Tools reachable from this session | Yes, 255 MCP tools | `binary_session` catalog counts |
| A tool call works | Yes, `inspect_desktop_application` on `/Applications/Anki.app` returned Evidence | Evidence `ev_8bdd38cd…` (in-memory, REA session) |
| Native decompilation (Hopper, Ghidra, IDA, Kuna) | Not available | `binary_session`: Ghidra `not_configured`, Hopper `executable_missing`, IDA `not_configured`, Kuna `not_configured` |
| Android tools (adb, jadx, apktool) | Not available | provider not configured |
| Linux-only tools (packet capture, firmware, JS source recovery with Wakaru, gdb/rizin) | Not available on macOS | `unsupported_host` |

## Blocker for the Rayyan flows

REA's browser tools (`list_browser_targets`, `inspect_web_page`, `observe_web_session`, `capture_browser_scenario`) need **either**:

1. **Connect mode**: a Chrome already running with a loopback DevTools port (for example `http://127.0.0.1:9222`). Checked: nothing is listening there (`endpoint_unreachable`). The user's everyday Chrome does not expose this port.
2. **Launch mode**: REA starts its own browser with an empty temporary profile. That browser is not signed in to Rayyan, and signing in would require giving REA the password, which we will not do.

What is needed from the user (one of):

- **A.** Start a separate Chrome window with a debugging port and a dedicated profile, sign in to Rayyan there by hand, then tell Claude. REA then connects to that window only. Close it when finished; while it is open, any program on the Mac could control that window through the port.
- **B.** Skip REA for the Rayyan part and let Claude observe Rayyan through Claude in Chrome in the everyday signed-in Chrome. Same rules (UI only, test review only).

## Other prerequisites still open

- **Second Rayyan account** (a colleague, or a second account of the user) to observe blind screening with two reviewers. Without it, only one reviewer's side can be observed.
- **Rayyan plan limits**: whether the user's plan allows creating another review and inviting a collaborator is unknown until checked in the account.
