# Architecture & integration notes

## Data flow

```
Chrome (world + COMMS)
        |  HTTP + SSE  http://127.0.0.1:8787
        v
StarNet sidecar (sidecar/index.js)
        |  OpenAI-compatible chat/completions  http://127.0.0.1:4000/v1
        v
OpencodeGoProxy.exe  (credential pool, 402/429/5xx failover)
        |  https://opencode.ai/zen/go/v1
        v
OpenCode Go API  (mimo-v2.5)
```

The sidecar and the proxy each run under their own Windows Scheduled Task (S4U, session 0) behind a supervisor
`.cmd` loop, so closing a terminal cannot take the station down.

## Why a proxy

OpenCode Go serves each model on exactly **one** wire protocol, and the account has a pool of keys where a key
can be out of funds. The proxy:

- pins each model to the protocol it actually answers on (`mimo-v2.5` = `chat/completions`),
- retries across the credential pool on `402 / 429 / 5xx`,
- exposes a single stable `http://127.0.0.1:4000/v1` endpoint with its own local bearer.

`scripts/probe-protocols.js` discovers the protocol per model; `scripts/probe-keys.js` reports per-key health.
Both are read-only and never print key material.

## Upstream changes (patches/starnet-opencodego.patch)

| File | Change |
|---|---|
| `sidecar/providers/registry.js` | `opencode-go` profile: `openai-compatible` adapter, `chat/completions`, env-driven key/base URL |
| `sidecar/providers/factory.js`, `provider.js` | wire the provider into the factory + WIRE_TARGETS |
| `sidecar/providers/errorClass.js` | a server-fault 400 (`type: server_error`, "Model is unavailable") is classified retryable + fallback instead of fatal |
| `sidecar/providers/responses.js` | *(new file)* generic OpenAI Responses adapter |
| `sidecar/cron-driver.js` | **crew-aware routines**: a scheduled fire is a `lead`, so the routine agent gets `team.dispatch` (opt out with `STARNET_CRON_LEAD=0`) |
| `sidecar/index.js` | same for Run Now; provider-aware DEV boot payload; no-questions gating; orchestration note prefers `team.dispatch` over `team.spawn`; **every real host run is registered in `hostLiveRuns`** so delegated workers appear in `GET /api/state/snapshot` and an SSE reconnect no longer drops the crew |
| `sidecar/tools/builtin/orchestration.js` | worker `agent.tool_call` forwarded **identity-only** so the floor can show each worker's live tool |
| `sidecar/run-journal.js` | self-heals on `ENOENT` |
| `frontend/app/world.js` | **live work bubbles**: a persistent per-agent status bubble fed by real events, with a TTL sweep |
| `frontend/app/app.js`, `harness.js`, `modeldock.js`, `frontend/index.html` | `opencode-go` normalization + the OPENCODE GO provider button |

## The three operational blockers this project fixes

1. **Budget deadlock** — an interrupted run leaves a dispatch-only receipt in `.spend-pending/`; the ledger
   refuses to guess `$0`, so spend history reads *unknown*. The launcher clears provably-stale receipts at a
   clean boot (`Clear-StaleSpendPending`).
2. **Unpriced-token ceiling** — OpenCode Go reports no per-token price, so every turn reconciles at `$0` and the
   default `2,000,000`-token seatbelt stopped a real mission mid-build. The launcher raises
   `STARNET_MAX_UNPRICED_TOKENS` to `50,000,000`.
3. **Solo routines** — a scheduled fire had no orchestrator object, so a "full-crew" routine silently did the
   whole job alone. Crew-aware routines make the fire a lead.

## Live work bubbles

`frontend/app/world.js` keeps `liveStatusByAgent` (agentId → `{ text, at, until }`):

- `agent.run.start` → `working…`
- `agent.tool_call` → `working: <TOOL>` (plus a clipped arg hint when the caller ships one)
- `agent.tool_result` → back to `working…`
- `agent.run.end` / `agent.run.error` → cleared
- `sweepStaleStates` drops anything older than the TTL

`drawBubble` renders the status only when there is no live speech, so one bubble is ever on screen per body.

## Configuration (environment)

| Variable | Purpose | Launcher default |
|---|---|---|
| `STARNET_CRON_ENABLED` | arm the scheduler | `1` |
| `STARNET_CRON_LEAD` | scheduled/Run-Now fires are leads (crew-aware) | `1` |
| `STARNET_MAX_UNPRICED_TOKENS` | per-run token seatbelt for unpriced models | `50000000` |
| `STARNET_FULL_ACCESS` | master full-access posture | `1` |
| `STARNET_NO_QUESTIONS` | suppress clarifying prompts | `1` |
| `STARNET_DEFAULT_MODEL` / `STARNET_DEFAULT_PROVIDER` | boot model/provider | `mimo-v2.5` / `opencode-go` |
| `OPENCODE_GO_API_KEY` / `OPENCODE_GO_BASE_URL` | provider credential + base | read from the proxy config |
