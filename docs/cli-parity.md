# CLI parity with the toolkit

Studio ships a headless CLI in the **same binary** as the GUI: if the first
argument is a subcommand, it runs to completion and exits without opening a
window (a bare trace path, or no arguments, opens the inspector instead). The CLI
mirrors the toolkit's `ocpp-debugkit` command surface (source of truth:
`packages/toolkit/src/cli/`); this table records the mapping and every
intentional difference.

| Toolkit command | Studio command | Parity |
| --- | --- | --- |
| `inspect <file>` | `studio inspect <file>` | ✅ Full — parses, analyzes, prints a counts + failures summary. |
| `report <file> -f <fmt>` | `studio report <file> [-f markdown\|html]` | ✅ Full — Markdown + self-contained HTML. |
| `diff <a> <b> --format <fmt>` | `studio diff <a> <b> [--format text\|json]` | ✅ Full — text and JSON. |
| `anonymize <file>` | `studio anonymize <file>` | ✅ Full — same field rules (see the anonymize module). |
| `ci [dir]` | `studio ci` | ⚠️ Runs the **vendored** `contract-v1` scenarios (Studio embeds the contract); the `[dir]` argument is not accepted. Exits `0` (all pass) / `1` (any fail). |
| `scenario list` | `studio scenario list` | ✅ Full. |
| `scenario run <name>` | `studio scenario run <name>` | ✅ Built-in scenarios. |
| `scenario run --file <path>` | — | ⚠️ Deferred — Studio runs only the built-in contract scenarios. |
| — | `studio capture --listen H:P --upstream ws://H:P [--ndjson]` | ➕ **Studio-only** — a live WebSocket MITM proxy; the toolkit is offline by charter. Relays a CP↔CSMS session, decodes + records it, runs detection. `--ndjson` streams each captured event as a JSONL line to stdout (redirect to save a trace). |

## Intentional differences

- **Output is stdout; no `-o <file>` flag.** Redirect to save:
  `studio report trace.json -f html > report.html`. The toolkit's `-o`
  convenience is a deferred follow-up (it needs the sandboxed `init.io` write
  path); redirection covers the same need today.
- **`ci` runs the embedded contract**, not a user directory. Studio vendors the
  15 `contract-v1` fixtures + goldens under `src/ocpp/conformance/` (ADR-0004),
  so `ci` is a self-contained conformance gate — the same logic the
  `native test` conformance harness runs.
- **One binary, two faces.** The CLI shares the exact pure engine the GUI uses
  (`src/ocpp/`); there is no separate code path to drift. A bare trace path opens
  the GUI: `studio path/to/trace.json`.
- **`capture` is Studio-only.** The toolkit is offline (parse / detect / report)
  by charter; live capture is the territory Studio was built to own (ADR-0001).
  It's a plaintext `ws://` MITM proxy today — `wss://` (TLS) is post-0.5
  (ADR-0008), hostname resolution is a follow-up (IP addresses for now), and it
  handles one session per invocation. Without `--ndjson` it prints a one-line
  summary; with `--ndjson`, stdout is the trace stream and the summary goes to
  stderr.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (for `ci` / `scenario run`: all scenarios matched their goldens). |
| `1` | Runtime failure — a file could not be read, or a scenario mismatched. |
| `2` | Usage error — a missing/invalid argument, or an unknown scenario name. |
