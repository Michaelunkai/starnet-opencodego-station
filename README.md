# StarNet x OpenCode Go Station

Wire the [StarNet](https://github.com/androoAGI/starnet) agent harness to the **OpenCode Go** API through a
self-healing local failover proxy, seed a full **8-agent crew**, and run a standing mission **unattended** — all
in Chrome, all on one machine.

![StarNet x OpenCode Go](assets/hero.png)

- **Model:** `mimo-v2.5` over the `chat/completions` wire
- **Brain:** a local `OpencodeGoProxy` on `http://127.0.0.1:4000/v1` with credential failover
- **UI:** StarNet sidecar on `http://127.0.0.1:8787`
- **Team:** NOVA + FOREMAN + RESEARCHER + ENGINEER + ANALYST + WRITER + SCOUT + OPERATOR

> **Deployment URL:** this project runs locally and is **not** deployed to the public internet. The live URL is
> the local station: `http://127.0.0.1:8787`. There is no hosted/public URL.
>
> **Source:** https://github.com/Michaelunkai/starnet-opencodego-station

---

## Architecture

![Architecture](assets/architecture.png)

One machine, four hops, zero external services beyond the OpenCode Go API:

1. **Chrome** loads the StarNet world + COMMS from `http://127.0.0.1:8787`.
2. The **sidecar** (`sidecar/index.js`) runs every agent loop, tool, routine and the SSE bridge.
3. The **proxy** (`OpencodeGoProxy.exe`) listens on `http://127.0.0.1:4000/v1`, holds the credential pool, and
   fails over on `402 / 429 / 5xx`.
4. **OpenCode Go** (`https://opencode.ai/zen/go/v1`) serves `mimo-v2.5`.

---

## Quick start

Prerequisites: **Windows PowerShell 5.1**, **Node.js**, **Chrome**, and a running **OpencodeGoProxy** with its
config (listen prefix + local bearer + upstream keys).

1. Clone upstream StarNet and place the three deployment scripts at the **repository root**:

   ```powershell
   git clone https://github.com/androoAGI/starnet.git C:\StarNet
   Copy-Item .\scripts\launch-opencodego.ps1            C:\StarNet\
   Copy-Item .\scripts\prepare-opencodego-station.js    C:\StarNet\
   Copy-Item .\scripts\kickoff-mission.ps1              C:\StarNet\
   ```

2. Apply the integration patch (adds the `opencode-go` provider profile, the Responses adapter, the
   crew-aware routines, and the live work bubbles):

   ```powershell
   cd C:\StarNet
   git apply ..\starnet-opencodego-station\patches\starnet-opencodego.patch
   Copy-Item ..\starnet-opencodego-station\patches\new-files\sidecar\providers\responses.js sidecar\providers\
   npm install ajv@8.20.0 undici@6.28.1 --no-save --ignore-scripts --package-lock=false
   ```

3. Run it:

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\StarNet\launch-opencodego.ps1
   ```

   Add `-NoBrowser` to skip opening Chrome, `-KeepRunning` to adopt an already-serving station, or
   `-ProxyDir <path>` to point at a different proxy folder.

---

## What the launcher does

![Features](assets/features.png)

1. **Resolves paths itself** — runs from the StarNet repo root *or* from `<project>\scripts\` (auto-detects the
   checkout; override with `-Repo`).
2. Verifies the proxy `/health`, then keeps it under a **self-healing scheduled task** (`StarNet-OpenCodeGoProxy`).
3. Validates the model against the live proxy catalog.
4. **Frees the port first** — stops the task, kills the sidecar's node, and kills *whatever* holds the port, then
   waits (bounded) until it is actually free. The station can never fail to bind behind a stale listener.
5. Performs a **clean restart**, clears stale spend receipts, and seeds the station
   (`prepare-opencodego-station.js`) with the hero + 7 specialists on `mimo-v2.5` / `opencode-go`, `approvalMode=full`.
6. Starts the sidecar under a **S4U scheduled task** (`StarNet-OpenCodeGo`) — session 0, no console — with a
   2-second supervisor loop so the station self-heals at both levels.
7. Turns on master bypass + no-questions mode, and sets full-crew concurrency.
8. Creates (and refreshes) the standing **mission routine** and kicks it off immediately, detached.
9. **Never hangs** — every wait is bounded and prints progress; a failure dumps the logs and exits with a reason.
10. Opens Chrome at `http://127.0.0.1:8787` while the mission is running, then prints the summary.

Verified end to end: the mission dispatches the **whole crew in parallel** — a live run shows
`agent, researcher, scout, analyst, foreman, engineer, writer, operator` all working at once.

---

## The crew

| Agent | Role | Job |
|---|---|---|
| **NOVA** | Orchestrator | Takes missions, delegates, monitors, reports |
| **FOREMAN** | Team Lead | Splits work, tracks workers, reissues stalled jobs |
| **RESEARCHER** | Researcher | Live web research, sourced claims |
| **ENGINEER** | Engineer | Reads before changing, builds and fixes, verifies by running |
| **ANALYST** | Analyst | Computes and verifies the numbers |
| **WRITER** | Scriptwriter | Docs, scripts and content in the requested voice |
| **SCOUT** | Scout | Watches sources, reports only real change |
| **OPERATOR** | Automator | Runs routine/scheduled work idempotently |

A scheduled routine is **crew-aware**: the routine's agent runs as a *lead* and can `team.dispatch` real work to
the named specialists, each of which runs its own independent agent loop.

---

## The task file

The launcher reads **`F:\downloads\a.md`** on every start and uses its contents as the mission objective, wrapped
with the crew-dispatch directive. Edit that file, re-run the launcher, and the whole crew works the new task. If
the file is missing or empty the launcher says so and falls back to the built-in default mission.

## Live work bubbles

![Live work bubbles](assets/bubbles.png)

While an agent is working, a persistent bubble over its head says **in plain English** what it is doing **right
now** — not a bare tool id. `web_search` becomes *Searching the web — "best time apps"*, `fs_write` becomes
*Writing a file — "app/index.html"*, `team.dispatch` becomes *Delegating work to the crew*. It is driven only by
real harness events (`agent.run.start` / `agent.tool_call` / `agent.run.end`); a real spoken line always wins the
single bubble, and a TTL sweep means a lost `run.end` degrades to silence instead of a stuck bubble. A late-opened
page or a reconnect **seeds** a bubble for any agent that is already working, so a bubble is present the whole time
an agent works. Crew tool activity is broadcast straight to the floor (`floorEmit`), so it is watchable no matter
how the lead was launched.

## Watching the whole crew

- The CREW rail shows `▮ N WORKING / ▯ M IDLE` from real run events (verified: `8 WORKING` with the whole crew).
- NOVA (the lead) shows its own live bubble and its mission session in COMMS, so you can read what it is doing and
  type instructions to redirect the whole staff.
- `scripts\launch-opencodego.ps1 -WatchSeconds 120` prints the live crew roster to the console while it runs.

---

## Repository layout

```
starnet-opencodego-station/
  README.md
  LICENSE                 MIT, with upstream attribution
  .gitignore
  assets/                 images, generated programmatically (no screenshots)
  docs/
    ARCHITECTURE.md       design notes and the exact upstream changes
  scripts/
    launch-opencodego.ps1        <- PRIMARY ENTRY POINT
    prepare-opencodego-station.js
    kickoff-mission.ps1
    probe-keys.js                credential health (never prints keys)
    probe-protocols.js           which wire each model speaks
  patches/
    starnet-opencodego.patch     unified diff against upstream StarNet
    new-files/sidecar/providers/responses.js
  tools/
    make-assets.ps1              regenerates every image in assets/
```

---

## Verification

- All scripts parse and run under **Windows PowerShell 5.1** (`powershell.exe`), not PowerShell 7.
- `tools/make-assets.ps1` regenerates the images deterministically (Windows PowerShell 5.1 + `System.Drawing`).
- `scripts/probe-keys.js` and `scripts/probe-protocols.js` are read-only diagnostics; they never print key material.
- No credentials, tokens or private keys are stored in this repository — the launcher reads the proxy's local
  bearer from the proxy's own `config.json` at runtime.

---

## License & attribution

MIT. Upstream StarNet is MIT, Copyright (c) 2026 Andrew Sims — see [LICENSE](LICENSE). This project is an
independent integration layer that patches a local StarNet checkout; it does not redistribute upstream source.
