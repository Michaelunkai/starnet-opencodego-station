/* STARNET — autosessions.js : surface an UNATTENDED cron/routine run as a readable SESSION.

   THE BUG THIS CLOSES. A cron routine fires headless (cron-driver.js fireJob → runOnce with
   surface:'autonomous', trigger:'schedule'). Its reply text is buffered server-side and only an
   OUTCOME enum escapes on cron.result — so the Commander hears the HUD chime + the away-digest
   toast but can never READ what the routine actually produced. There was no session, no thread,
   no output. This module makes an unattended run appear as a real workstream the instant it fires
   (rail row, marked busy) and folds its durable transcript into that session when it completes —
   Claude-Code / reference-harness session-list parity.

   HOW IT WORKS (no new events; the contract is OWNED). A scheduled fire runs under the stream its
   routine DECLARED (cron-driver.js:501) and every one of its transcript rows is stamped with the run
   id, so its dialogue is durable and fetchable via the same transcriptStore every attended run uses.
   This layer is a READ-ONLY citizen of U.bus:
     · cron.fire {jobId, runId}  → ADOPT a workstream id 'cron-<runId>' (title = routine name from
       the /api/cron catalogue, agentId = the job's agent, lane 'active', history seeded with the
       routine's prompt as the user turn) and mark it busy — WITHOUT stealing the Commander's
       focus. The rail row appears immediately.
     · cron.result {jobId, runId, outcome} → read the run's durable transcript down a WIDENING LADDER
       (see fetchTranscript), fold the run's real dialogue into that session's history in chat.js's
       exact shape, clear busy, persist, re-render. A 'failed' outcome appends an honest error line.
     · BOOT BACKFILL: on init, read /api/runs?agent=*, and for every run whose streamId starts
       'cron-' with no live session, adopt + backfill it — so routines that ran while the browser
       was CLOSED are also readable. Bounded + fail-open (a route error → no crash, no fake rows).

   THE TWO STATUS SPAM LINES ARE GONE (2026-10-01). A settled run with no readable prose used to end
   with one of two stock status sentences — a line declaring the routine's run uneventful, and a line
   warning that its output had yet to land and would be retried when the session opens — and eight
   specialists ticking every three minutes stacked them until the chat was nothing but filler. Neither
   sentence appears anywhere in this file now. Both came from the same root cause: the read asked for a
   stream the crew never writes to (see the ladder), so it answered ZERO turns and the fold mistook
   "empty" for "nothing happened". Three things now hold:
     1. the ladder finds the stream the run really wrote to, so the real prose is folded;
     2. the sidecar ends every run with a real line (STARNET_CREW_ALWAYS_REPORTS + ensureRunReported);
     3. when a run STILL leaves nothing, this module writes one truthful REPORT LINE built from that
        run's own recorded tool calls — never a stock sentence, never repeated, and it names the agent.
   A settled session always therefore holds at least one row, which also keeps chat.js from drawing its
   OWN pending-transcript warning; and because a report line is marked `autoReport` it never satisfies
   the readable-output guard, so the heal pass still replaces it with the run's real output.

   Follows the *store.js wiring pattern (returnstore/autojobstore): a plain init()/reset() surface,
   never .emit()s (lint-emits stays green), self-contained, reads the same /api routes the return
   ritual reads. Depends on the Workstreams / Channels / Chat / App globals loaded before it. */
'use strict';
const AutoSessions = (() => {
  const STREAM_PREFIX = 'cron-';
  let routines = null;         // jobId -> { name, agentId, prompt } cache from /api/cron (lazy)
  let wired = false;           // U.bus subscriptions installed once
  let backfilling = false;     // in-flight boot backfill guard (idempotent)

  // presence guards use `typeof X` (bare identifier) — App/Chat are top-level `const`s, NOT window props,
  // so `window.App` is undefined even though the `App` binding resolves. Match how chat.js probes App.
  const hasWS = () => typeof Workstreams !== 'undefined' && Workstreams;
  const hasCh = () => typeof Channels !== 'undefined' && Channels;
  const hasChat = () => typeof Chat !== 'undefined' && Chat;
  const hasApp = () => typeof App !== 'undefined' && App;
  const hasU = () => typeof U !== 'undefined' && U && U.bus && U.bus.on;
  const streamOf = (runId) => STREAM_PREFIX + String(runId);
  // 'cron-' + a runId (crypto.randomUUID: hex + hyphens) fits the workstream/stream grammar (/^[A-Za-z0-9_-]{1,64}$/).
  function validStream(id) { return /^cron-[A-Za-z0-9_-]{1,58}$/.test(String(id || '')); }
  function outcomeOfRun(run) {
    if (!run) return null;
    if (run.error || run.reason === 'error' || run.reason === 'failed') return 'failed';
    return run.reason === 'done' ? 'ok' : null;
  }
  // A cron stream is named after ONE real run. Repair legacy stream-as-run ids, but never settle a
  // later attended follow-up using the earlier scheduled run's outcome.
  function recordOutcome(ws, outcome, endedAt) {
    if (!ws || !validStream(ws.id) || !hasWS()) return;
    const runId = ws.id.slice(STREAM_PREFIX.length);
    const ids = Array.isArray(ws.runIds) ? ws.runIds : [];
    if (ids.includes(ws.id)) ws.runIds = ids.map(id => id === ws.id ? runId : id).filter((id, i, all) => all.indexOf(id) === i);
    const current = ws.runIds || ids;
    if (current.length && current[current.length - 1] !== runId) return;
    if (Workstreams.appendRun) Workstreams.appendRun(ws.id, runId, endedAt);
    // noteRunEnd accepts a boolean, so unknown must never be passed through as false (or true).
    if (Workstreams.noteRunEnd && (outcome === 'ok' || outcome === 'silent' || outcome === 'failed')) Workstreams.noteRunEnd(ws.id, runId, outcome !== 'failed');
  }

  /* ── WHAT COUNTS AS OUTPUT ──────────────────────────────────────────────────────────────────────
     Three questions that must not be confused with one another:
       · hasReadableOutput()      "does this thread hold REAL prose?" A report line this module wrote
                                  (autoReport) is NOT real prose — it exists so a settled session is
                                  never blank, and it must not make a later heal think the session is
                                  already hydrated.
       · chat.js's `readable`    "will chat.js add its OWN pending-transcript warning?" Any non-empty
                                  row settles it, including a settled sys row. That is why a session
                                  this module settles always carries at least one row.
       · a transcript read       "does the DURABLE record hold prose for THIS agent, from THIS run?"
     Keeping the three straight is what makes the stock status sentences unnecessary. */
  const txt = (v) => String(v == null ? '' : v);
  const RUN_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
  // The sidecar still offers "[SILENT]" in its routine note (index.js CRON_ROUTINE_NOTE) even where
  // STARNET_CREW_ALWAYS_REPORTS forbids the answer, so a run CAN still reply with the token. It is a
  // CONTROL token, not output: recognised here and never rendered. A run that answered only with it falls
  // through to runReport(), which names what it actually did — the truthful version of the quiet line this
  // module used to emit for it.
  const SILENT_TOKENS = ['[SILENT]', 'SILENT'];
  const isSilentToken = (s) => SILENT_TOKENS.indexOf(txt(s).trim().replace(/^["'\u201c]+|["'\u201d]+$/g, '')) !== -1;
  // Harness rows the sidecar injects as user turns (chat.js filters the same two shapes when it merges).
  // They are not the routine's own words and must never become a session's prompt.
  const internalPacket = (s) => /^Shared conversation context \(/.test(txt(s)) || /^\[BEGIN EXTERNAL SCREEN CAPTURE/.test(txt(s));
  function hasReadableOutput(history) {
    return (Array.isArray(history) ? history : []).some(m => m && !m.autoReport && (
      (m.role === 'assistant' && txt(m.content).trim()) ||
      (m.sys && !m.transcriptPending && txt(m.content).trim())
    ));
  }

  /* THE ROWS OF ONE READ THAT BELONG TO THIS SESSION. A rung can answer with far more than this
     session's dialogue: the mission feed carries EVERY agent's turns, and an unscoped read of a
     routine's own stream carries its earlier ticks. Two cuts, both grounded in the durable record:
       · RUN SCOPE — this run's rows, plus unstamped harness rows (the sidecar's own end-of-run report
         line is appended with no sourceRunId). Every other run's rows are not this session's dialogue.
       · AUTHOR SCOPE — a private stream keeps rows with no agent or with this session's agent; the
         SHARED mission feed keeps only rows this session's agent actually wrote, so another
         specialist's line can never land here unattributed (chat.js owns the unified feed + labels). */
  function ownedRows(agentId, turns, shared, runId) {
    const aid = txt(agentId) || 'agent';
    return (Array.isArray(turns) ? turns : []).filter(t => t
      && (t.role === 'user' || t.role === 'assistant')
      // RUN SCOPE, per row: an unscoped read interleaves runs chronologically, so this run's rows are not a
      // contiguous block. Keep what it stamped, plus unstamped harness rows (the sidecar appends its own
      // end-of-run report line with no sourceRunId); every other run's rows are simply not ours.
      && (!runId || !txt(t.sourceRunId) || txt(t.sourceRunId) === runId)
      // AUTHOR SCOPE
      && (shared ? txt(t.agentId) === aid : (!txt(t.agentId) || txt(t.agentId) === aid)));
  }
  // "Prose worth showing" — the test the ladder stops on and the test foldTurns folds.
  function readableInTurns(agentId, turns, shared, runId) {
    return ownedRows(agentId, turns, shared, runId)
      .filter(t => t.role === 'assistant' && txt(t.content).trim() && !isSilentToken(t.content));
  }

  /* THE LADDER — which stream a run's dialogue can actually be on.
     A session is NAMED after its run ('cron-<runId>'), but a run PERSISTS under the stream its routine
     declared — `crew-<agentId>` for a specialist and `global` for the mission (cron-driver.js:501 takes
     origin.streamId when the job has one). Asking only for `cron-<runId>` therefore returned ZERO turns
     for every crew routine, which is precisely what produced the old routine-quiet / output-pending lines
     while the crew was in fact working hard. Rungs, in order, stopping at the first
     read that carries THIS session's prose:
       1. the session's own stream, scoped to this run (&runId=)  — a no-origin routine's private stream
       2. the session's own stream, unscoped                     — harness rows carry no sourceRunId
       3. `crew-<agentId>`,         scoped to this run           — what a specialist declares
       4. `crew-<agentId>`,         unscoped
       5. the shared mission feed,   scoped to this run          — no `stream=` at all
       6. the shared mission feed,   unscoped                    — last resort
     live=1 on every rung, so in-flight turns come back and the session fills while the run works. */
  function ladderFor(agentId, streamId, runId) {
    const sid = txt(streamId);
    const own = 'crew-' + (txt(agentId) || 'agent');
    const rungs = [], seen = {};
    const add = (stream, scoped, shared, label) => {
      const scopedNow = !!(scoped && runId);
      const key = (stream || '#shared') + '|' + (scopedNow ? 'run' : 'all');
      if (seen[key]) return;
      seen[key] = 1;
      rungs.push({ stream: stream, scoped: scopedNow, shared: !!shared, label: label });
    };
    if (sid) { add(sid, true, false, sid); add(sid, false, false, sid); }
    if (own !== sid) { add(own, true, false, own); add(own, false, false, own); }
    add('', true, true, 'global (mission feed)');
    add('', false, true, 'global (mission feed)');
    return rungs;
  }
  // chat.js bounds its transcript read with an AbortController; an unbounded fetch here would wedge the
  // fold (and the session's busy state) for as long as the sidecar stalls.
  async function fetchWithTimeout(url, ms) {
    if (typeof AbortController === 'undefined') return fetch(url, { cache: 'no-store' });
    const ctl = new AbortController();
    const timer = setTimeout(() => { try { ctl.abort(); } catch (_) {} }, Math.max(250, Number(ms) || 8000));
    try { return await fetch(url, { cache: 'no-store', signal: ctl.signal }); }
    finally { clearTimeout(timer); }
  }

  // cron.result can beat the final transcript append. Retry only that short persistence window and
  // remember whether ANY complete read succeeded, so foldTurns can tell an honestly EMPTY transcript
  // from an UNREACHABLE one. `fetchOk` is sticky for the whole fold: it must never claim "unreachable"
  // because the last rung of the last attempt failed after earlier rungs already answered.
  async function fetchTranscript(agentId, streamId, options) {
    const opts = options || {};
    const sid = txt(streamId);
    const fromId = sid.indexOf(STREAM_PREFIX) === 0 ? sid.slice(STREAM_PREFIX.length) : '';
    const rid = RUN_ID_RE.test(txt(opts.runId)) ? txt(opts.runId) : (RUN_ID_RE.test(fromId) ? fromId : '');
    const waits = Array.isArray(opts.waits) ? opts.waits : [120, 400];
    const sleep = opts.sleep || (ms => new Promise(resolve => setTimeout(resolve, ms)));
    const rungs = ladderFor(agentId, sid, rid);
    let best = [], bestN = 0, fetchOk = false, rung = null, attempts = 0;

    for (let attempt = 0; attempt <= waits.length; attempt++) {
      for (const r of rungs) {
        const url = '/api/transcript?agent=' + encodeURIComponent(txt(agentId) || 'agent')
          + (r.stream ? '&stream=' + encodeURIComponent(r.stream) : '')
          + (r.scoped && rid ? '&runId=' + encodeURIComponent(rid) : '')
          + '&limit=200&live=1';
        attempts++;
        let body = null;
        try {
          const res = await fetchWithTimeout(url, opts.timeoutMs || 8000);
          // The STATION did not answer. Every rung is the same host, so no other stream can produce an
          // answer this one could not: end the pass and spend the retry on the transport instead of on
          // four more identical refusals.
          if (!res || !res.ok) break;
          body = await res.json();
        } catch (_) { break; }
        if (!body || !Array.isArray(body.turns)) continue;   // malformed is unknown, never "empty"
        fetchOk = true;
        const turns = body.turns;
        if (readableInTurns(agentId, turns, r.shared, rid).length) {
          return { turns: turns, fetchOk: true, rung: r, runId: rid, attempts: attempts, readable: true };
        }
        // keep the richest evidence: runReport() reads this run's tool calls out of it
        if (turns.length > bestN) { bestN = turns.length; best = turns; rung = r; }
      }
      if (attempt < waits.length) await sleep(waits[attempt]);
    }
    return { turns: best, fetchOk: fetchOk, rung: rung, runId: rid, attempts: attempts, readable: false };
  }

  // ---- routine catalogue (names + prompts) ----------------------------------------------------
  async function loadRoutines() {
    try {
      const r = await fetch('/api/cron', { cache: 'no-store' });
      if (!r.ok) return (routines = routines || {});
      const jobs = ((await r.json()) || {}).jobs || [];
      const map = Object.create(null);
      for (const j of jobs) {
        if (!j || !j.id) continue;
        map[j.id] = { id: j.id, name: String(j.name || '').trim(), agentId: String(j.agentId || 'agent'), prompt: String(j.prompt || '') };
      }
      routines = map;
    } catch (_) { routines = routines || {}; }   // fail-open: names are cosmetic, a session still forms
    return routines;
  }
  function routineFor(jobId) { return (routines && routines[jobId]) || null; }

  // ---- session lifecycle ----------------------------------------------------------------------
  // Adopt (idempotent) the session for one cron run and mark it busy WITHOUT stealing focus. `job`
  // (optional) supplies the human title / agent / seeding prompt; absent, the row still forms honestly.
  function beginSession(runId, job) {
    if (!hasWS()) return null;
    const id = streamOf(runId);
    if (!validStream(id)) return null;
    const title = (job && job.name) || 'Routine';
    const agentId = (job && job.agentId) || 'agent';
    const seed = (job && job.prompt) ? [{ role: 'user', content: String(job.prompt) }] : [];
    const ws = Workstreams.adopt({ id: id, title: title, agentId: agentId, lane: 'active', history: seed,
      automation: { kind: 'routine', id: (job && job.id) || '', name: title } });
    if (!ws) return null;   // a session the Commander DELETED stays deleted (adopt refused the tombstoned id)
    // mark the row busy via the SAME per-workstream channel state chat.js drives (Channels.begin) so the
    // rail's railRowState paints the pulsing "running" dot — reused, not a bespoke busy flag.
    if (hasCh() && !Channels.isBusy(id)) { Channels.begin(id, Date.now()); Channels.setStatus(id, 'thinking…'); }   // cron.fire IS server truth — skip the 'connecting…' unconfirmed state
    armReconcilePoll();   // a live cron run → keep a bounded poll ready to heal it if the result event is lost
    refreshRail();
    persist();
    return ws;
  }

  // Fold a completed run's durable transcript into its session, clear busy, persist, re-render.
  // `endedAt` (optional, epoch ms): the run record's REAL end time — passed by the heal/backfill paths that
  // learn about a run after the fact, so the session's "last worked" stamp is the run's, not the poll's.
  async function completeSession(runId, outcome, reason, endedAt) {
    if (!hasWS()) return;
    const id = streamOf(runId);
    if (!validStream(id)) return;
    // event-ordering safety: result may arrive before we processed fire (or after a backfill miss) — ensure
    // the session exists, seeding from the routine cache when we have it.
    let ws = Workstreams.get(id);
    if (!ws) ws = beginSession(runId, routineFor(/* jobId unknown here */ '') || null);
    if (!ws) return;

    const loaded = await fetchTranscript(ws.agentId, id, { runId: runId });

    foldTurns(ws, loaded.turns, outcome, reason, loaded.fetchOk, endedAt, loaded);
    if (hasCh()) Channels.end(id);   // clear the busy/running channel state
    // if this session is the one on screen, re-render it so the folded output is visible immediately.
    if (hasChat() && Workstreams.activeId && Workstreams.activeId() === id) Chat.load(ws);
    refreshRail();
    persist();
    // Nothing readable yet? The run's last turn can still be settling, and the transcript route can be
    // mid-restart. A couple of bounded re-reads turn a premature report line into the real output.
    if (loaded.readable) clearHeal(runId); else scheduleHeal(runId, outcome, reason, endedAt);
  }

  /* THE REPORT LINE — what a settled run that produced no prose of its own now says.
     This is the replacement for BOTH stock status sentences. Every clause is read from THIS run's own
     durable transcript rows (the tool names and the targets it really passed) plus the run record's
     outcome, so it indexes the run instead of filling the chat, it names the agent, and it carries the
     run's clock — which is why it can never repeat. It is marked `autoReport`, so it does NOT satisfy
     hasReadableOutput and the heal pass still replaces it with the run's real output once it lands. */
  function toolActions(turns, runId) {
    const acts = [];
    for (const t of (Array.isArray(turns) ? turns : [])) {
      if (!t || t.role !== 'assistant' || !t.toolCalls) continue;
      if (runId && t.sourceRunId && txt(t.sourceRunId) !== runId) continue;
      let calls = null;
      try { calls = JSON.parse(t.toolCalls); } catch (_) { calls = null; }
      if (!Array.isArray(calls)) continue;
      for (const c of calls) {
        const fn = (c && c.function) ? c.function : null;
        if (!fn || !fn.name) continue;
        let arg = '';
        try {
          const a = JSON.parse(fn.arguments || '{}') || {};
          for (const k of ['path', 'file', 'query', 'url', 'command', 'cmd', 'pattern', 'target']) {
            if (typeof a[k] === 'string' && a[k].trim()) { arg = a[k].trim().replace(/\s+/g, ' '); break; }
          }
        } catch (_) {}
        if (arg.length > 48) arg = arg.slice(0, 48) + '…';
        acts.push(arg ? (String(fn.name) + ' ' + arg) : String(fn.name));
      }
    }
    return acts;
  }
  function clockOf(ms) {
    const t = Number(ms) > 0 ? Number(ms) : Date.now();
    try { return new Date(t).toISOString().slice(11, 19) + 'Z'; } catch (_) { return ''; }
  }
  function routineLabel(ws) {
    return txt((ws && ws.automation && ws.automation.name) || (ws && ws.title) || 'Routine').split('\n')[0].slice(0, 60);
  }
  function runReport(ws, loaded, outcome, reason, endedAt) {
    const aid = txt(ws && ws.agentId) || 'agent';
    const rid = txt(loaded && loaded.runId);
    const uniq = [];
    for (const a of toolActions(loaded && loaded.turns, rid)) if (uniq.indexOf(a) === -1) uniq.push(a);
    const shown = uniq.slice(0, 3), more = uniq.length - shown.length;
    let body;
    if (!(loaded && loaded.fetchOk)) {
      body = 'no transcript was readable for run ' + (rid || '?') + ' after '
        + Math.max(1, Number(loaded && loaded.attempts) || 1) + ' attempts';
    } else if (uniq.length) {
      body = uniq.length + ' recorded step' + (uniq.length === 1 ? '' : 's') + ' ('
        + shown.join('; ') + (more > 0 ? '; +' + more + ' more' : '') + ') and no closing report line';
    } else {
      body = 'its transcript holds no readable line for this run';
    }
    const why = txt(reason).slice(0, 90);
    const end = outcome === 'failed' ? ('run ended: failed' + (why ? ' — ' + why : ''))
      : (outcome === 'ok' ? 'run ended: done' : '');
    return '✦ ' + routineLabel(ws) + ' · ' + aid + ' — ' + body + (end ? '; ' + end : '') + ' · ' + clockOf(endedAt);
  }

  // Fold server transcript rows into ws.history in chat.js's native shape. REAL dialogue is user/assistant
  // prose; our own framing lines (a failed run, or the report of a run that wrote no line) are STATUS rows —
  // role:'system' with sys:true — NOT role:'assistant'. That matters twice (Lane 5): chat.js renders a sys row
  // as a system-styled line (not agent speech), and historyWindow() EXCLUDES sys rows so a frontend-authored
  // string is never replayed back to the model as a prior assistant turn.
  // ORDER: keep what the SESSION owns (its seeded prompt, anything already in the thread) → fold this run's
  // real dialogue → append the run's verdict, or the report line when it wrote none. The two stock status
  // sentences this file used to emit are gone for good, and `fetchOk` now only decides WHICH truthful report
  // is written, never whether filler is.
  function foldTurns(ws, turns, outcome, reason, fetchOk, endedAt, loaded) {
    const meta = loaded || {};
    const rid = RUN_ID_RE.test(txt(meta.runId))
      ? txt(meta.runId)
      : (validStream(ws && ws.id) ? ws.id.slice(STREAM_PREFIX.length) : '');
    const shared = !!(meta.rung && meta.rung.shared);
    const read = {
      turns: turns, fetchOk: !!fetchOk, rung: meta.rung || null, runId: rid,
      attempts: Number(meta.attempts) || 0, readable: !!meta.readable
    };
    const mine = ownedRows(ws && ws.agentId, turns, shared, rid);
    read.readable = mine.some(t => t.role === 'assistant' && txt(t.content).trim() && !isSilentToken(t.content));

    // 1. what the session already owns. Previously folded transcript rows are re-derived from the fresh
    //    read below rather than carried blind, and sys rows are re-derived too (never stacked).
    const next = [];
    for (const row of (Array.isArray(ws && ws.history) ? ws.history : [])) {
      if (!row || row.sys || row.transcriptRow) continue;
      if (row.role === 'user') next.push(row);
      else if (row.role === 'assistant' && txt(row.content).trim()) next.push(row);
    }
    // 2. this run's real dialogue, attributed to the agent that wrote it.
    let hasUser = next.some(r => r.role === 'user');
    for (const t of mine) {
      const content = txt(t.content);
      if (t.role === 'user') {
        if (hasUser || internalPacket(content) || !content.trim()) continue;   // a harness packet or a duplicate of the seeded prompt
        next.push({ role: 'user', content: content, transcriptRow: true });
        hasUser = true;
        continue;
      }
      if (!content.trim()) continue;          // blank assistant envelope = tool-call transport, never output
      if (isSilentToken(content)) continue;   // the [SILENT] control token is never rendered as a chat line
      next.push({ role: 'assistant', content: content, transcriptRow: true, agentId: txt(t.agentId) || txt(ws && ws.agentId),
        ts: t.ts, sourceRunId: t.sourceRunId });
    }
    // 3. the run's verdict — or, when it wrote no line of its own, an honest index of what it DID do.
    const sysRow = (content, error, pending, autoReport) => {
      const m = { role: 'system', sys: true, content: String(content) };
      if (error) m.error = true;
      if (pending) m.transcriptPending = true;
      if (autoReport) m.autoReport = true;
      return m;
    };
    const saidSomething = next.some(m => (m.role === 'assistant' && txt(m.content).trim()) || (m.sys && txt(m.content).trim()));
    if (outcome === 'failed') {
      // a FAILED run must never look like it produced nothing: an honest error line, naming the routine
      // and the agent that ran it. (Never a pending marker — chat.js would draw its own pending warning.)
      const why = txt(reason || 'run failed').trim();
      next.push(sysRow('⚠ ' + routineLabel(ws) + ' (' + (txt(ws && ws.agentId) || 'agent') + ') failed'
        + (why ? ' — ' + why : ''), true));
    } else if (!saidSomething) {
      // nothing readable, and not a failure. Do NOT print a stock sentence: report what the run actually
      // recorded. autoReport keeps this row out of hasReadableOutput, so the heal pass still heals it.
      next.push(sysRow(runReport(ws, read, outcome, reason, endedAt), !read.fetchOk, false, true));
    }
    // SAY IT ONCE. Identical consecutive status rows collapse into a single line carrying an honest repeat
    // count, so N identical ticks read as one counted line instead of N copies of a sentence.
    const collapsed = [];
    for (const m of next) {
      const prev = collapsed.length ? collapsed[collapsed.length - 1] : null;
      if (prev && prev.role === 'system' && m.role === 'system' && prev.sys && m.sys &&
          String(prev.content) === String(m.content)) {
        prev.repeat = (prev.repeat || 1) + 1;
        continue;
      }
      collapsed.push(m);
    }
    for (const m of collapsed) {
      if (m.repeat && m.repeat > 1) m.content = String(m.content) + '  (×' + m.repeat + ')';
    }
    ws.history = collapsed;
    // hybrid-honest: a real run fired → todo advances to active. `endedAt` (heal/backfill paths) = the run
    // record's REAL end time, so the rail stamp is the run's, never this poll/boot moment.
    recordOutcome(ws, outcome, endedAt);
  }

  // ---- bounded heal: a run's last turn can settle AFTER cron.result, and a read can lose the race ------
  // The ladder's window covers the common persistence race; when it still finds nothing, the session would
  // otherwise keep its report line forever. Two re-reads, then stop: real output replaces the report and the
  // session is truthful again. If nothing ever lands, the report line STANDS — it is already true.
  const HEAL_DELAYS = [1200, 3600];
  const healTimers = new Map();
  function clearHeal(runId) {
    const list = healTimers.get(runId);
    if (!list) return;
    for (const t of list) clearTimeout(t);
    healTimers.delete(runId);
  }
  function scheduleHeal(runId, outcome, reason, endedAt) {
    if (!RUN_ID_RE.test(txt(runId)) || healTimers.has(runId)) return;
    const list = [];
    healTimers.set(runId, list);
    HEAL_DELAYS.forEach((ms, i) => {
      list.push(setTimeout(() => {
        if (i >= HEAL_DELAYS.length - 1) healTimers.delete(runId);
        healRun(runId, outcome, reason, endedAt);
      }, ms));
    });
  }
  async function healRun(runId, outcome, reason, endedAt) {
    const id = streamOf(runId);
    const ws = hasWS() && Workstreams.get ? Workstreams.get(id) : null;
    if (!ws || hasReadableOutput(ws.history)) return;      // real output already landed — nothing to heal
    const loaded = await fetchTranscript(ws.agentId, id, { runId: runId, waits: [] });
    if (!loaded.readable) return;                          // still nothing durable: the report line stands
    clearHeal(runId);
    foldTurns(ws, loaded.turns, outcome, reason, loaded.fetchOk, endedAt, loaded);
    if (hasChat() && Workstreams.activeId && Workstreams.activeId() === id) Chat.load(ws);
    refreshRail();
    persist();
  }

  // ---- busy reconciliation: heal a session wedged 'RUNNING' after a mid-run SSE drop -----------
  // The busy state a cron fire sets (Channels.begin) is cleared ONLY by cron.result. If the SSE bridge drops
  // between fire and result, that event is LOST and the session stays RUNNING forever — which also blocks the
  // Commander from typing into it (chat.js: `if (Channels.isBusy(ws.id)) return`). A run is recorded in the
  // runStore ONLY when it finishes, so: for each busy cron session, ask /api/runs whether its runId is now done;
  // if so, complete it (fold transcript + Channels.end). Fail-open, self-contained, no new events.
  let reconcilePoll = null;
  async function reconcileBusy() {
    if (!hasWS() || !hasCh() || !Channels.busyIds) return;
    const busy = Channels.busyIds().filter(id => String(id).indexOf(STREAM_PREFIX) === 0 && validStream(id));
    if (!busy.length) { stopReconcilePoll(); return; }
    for (const sid of busy) {
      const ws = Workstreams.get(sid);
      const runId = String(sid).slice(STREAM_PREFIX.length);
      let done = null;
      try {
        const r = await fetch('/api/runs?agent=' + encodeURIComponent((ws && ws.agentId) || 'agent') + '&runId=' + encodeURIComponent(runId), { cache: 'no-store' });
        if (r.ok) { const rows = ((await r.json()) || {}).runs || []; done = rows.find(x => x && x.runId === runId) || null; }
      } catch (_) { done = null; }   // offline / bridge still down → leave it busy, retry next tick
      if (done) {
        const outcome = outcomeOfRun(done);
        await completeSession(runId, outcome, done.error || done.reason, done.ts);   // folds transcript + Channels.end; done.ts = the run's REAL end time
      }
    }
    if (!Channels.busyIds().some(id => String(id).indexOf(STREAM_PREFIX) === 0)) stopReconcilePoll();
  }
  // a bounded self-poll: armed whenever a cron session goes busy, it retries reconcileBusy on a slow cadence
  // (covers an SSE drop with no reconnect event to hook) and self-stops once no cron session is busy. Bounded so
  // a genuinely long run doesn't poll forever — it caps out, then boot backfill / the next fire re-arms it.
  function armReconcilePoll() {
    if (reconcilePoll) return;
    if (!hasCh() || !Channels.busyIds || !Channels.busyIds().some(id => String(id).indexOf(STREAM_PREFIX) === 0)) return;   // nothing busy → nothing to poll
    let left = 40;   // ~10 min at 15s — long enough for any real cron run; boot backfill is the backstop past that
    reconcilePoll = setInterval(() => { if (--left <= 0) { stopReconcilePoll(); return; } reconcileBusy(); }, 15000);
  }
  function stopReconcilePoll() { if (reconcilePoll) { clearInterval(reconcilePoll); reconcilePoll = null; } }

  /* RE-READ THE SESSIONS THAT ARE STILL UNREADABLE (boot). A reload can restore a session whose only content
     is a report line — the fold ran while the transcript route was restarting. Re-read exactly those, and
     ONLY those the Commander already has: no adoption happens here, so the rail never grows a row from this
     pass. Bounded (24 sessions), sequential, fail-open. */
  async function healUnreadable(options) {
    if (!hasWS() || !Workstreams.all) return 0;
    const opts = Object.assign({ waits: [80] }, options || {});   // a restored report line is not a live race
    let healed = 0;
    const stale = (Workstreams.all() || []).filter(w => w && validStream(w.id) && !hasReadableOutput(w.history)).slice(0, 24);
    for (const w of stale) {
      const runId = w.id.slice(STREAM_PREFIX.length);
      const loaded = await fetchTranscript(w.agentId, w.id, Object.assign({ runId: runId }, opts));
      if (!loaded.readable) continue;    // nothing durable: the report line stands, truthfully
      foldTurns(w, loaded.turns, null, '', loaded.fetchOk, Number(w.lastActiveAt) || null, loaded);   // keep the run's own stamp
      healed++;
    }
    return healed;
  }

  // ---- boot backfill: sessions for cron runs that finished while the browser was CLOSED ---------
  /* BOOT COST IS BOUNDED. The ladder is wider than the single stream this used to ask for, so a boot with
     many unreadable cron sessions must not turn into a read storm: one short retry pass per session and a
     hard cap on how many sessions one boot will fold. Everything here is fail-open — a session that misses
     the cut is picked up by the next boot or the next reconcile, never faked. */
  const BACKFILL_MAX = 40;
  async function backfill(options) {
    if (backfilling || !hasWS()) return;
    backfilling = true;
    try {
      await loadRoutines();   // names first so backfilled rows are titled
      const opts = Object.assign({ waits: [80] }, options || {});   // a DONE run's rows are already durable
      let runs = [];
      try {
        const r = await fetch('/api/runs?agent=*&limit=100', { cache: 'no-store' });
        if (r.ok) runs = ((await r.json()) || {}).runs || [];
      } catch (_) { return; }   // route error → nothing to backfill, never crash
      /* THE RUN THAT DEFINES A SESSION IS THE ONE IT IS NAMED AFTER. A stream can now hold SEVERAL runs — a
         routine that fires a WORK LINE records one row per stage, all under 'cron-<runId>' so the session shows
         the whole line. Taking whichever row the list happened to yield first therefore titled the routine's
         session with the internal PIPELINE HANDOFF prompt and attributed it to the LAST stage's agent. The
         session id carries its defining runId, so pick that row exactly rather than by list order. */
      const byStream = Object.create(null);
      for (const run of runs) {
        const sid = run && run.streamId;
        if (!sid || String(sid).indexOf(STREAM_PREFIX) !== 0) continue;
        const want = String(sid).slice(STREAM_PREFIX.length);
        if (!byStream[sid] || String(run.runId || '') === want) byStream[sid] = run;
      }
      const seen = Object.create(null);
      let folded = 0;
      for (const run of Object.keys(byStream).map(k => byStream[k])) {
        const sid = run && run.streamId;
        if (!sid || String(sid).indexOf(STREAM_PREFIX) !== 0 || !validStream(sid)) continue;
        if (seen[sid]) continue;
        if (folded >= BACKFILL_MAX) break;
        seen[sid] = 1;
        folded++;
        // ORPHAN FIX (Lane 5): a reload MID-RUN leaves an ADOPTED busy session in Workstreams with the user seed
        // but NO assistant reply. The old dedupe skipped ANY existing session, permanently orphaning that output.
        // Now: skip only a session that has ALREADY folded a reply (a real dedupe); an existing session with no
        // assistant turn yet is folded from its (now-complete) durable transcript. A run only appears in this
        // /api/runs list once it's DONE, so backfilling it here is correct — and it also clears the wedged busy
        // state (foldTurns → completeSession-style, plus Channels.end below).
        const existing = Workstreams.get(sid);
        if (existing && run.cronJobId) Workstreams.adopt({ id: sid, automation: { kind: 'routine', id: run.cronJobId, name: run.cronJobName || run.title || 'Routine' } });
        const runId = String(sid).slice(STREAM_PREFIX.length);
        const outcome = String(run.runId || '') === runId ? outcomeOfRun(run) : null;
        if (existing && hasReadableOutput(existing.history)) {
          // Transcript dedupe is not metadata dedupe: upgrade saved cron streams with real provenance/outcome.
          if (String(run.runId || '') === runId) recordOutcome(existing, outcome, run.ts);
          if (hasCh()) Channels.end(sid);
          continue;
        }
        // adopt (idempotent) — an existing seed-only session is preserved by adopt; a while-away run is already DONE.
        Workstreams.adopt({ id: sid, title: String(run.title || 'Routine').split('\n')[0].slice(0, 80) || 'Routine', agentId: String(run.agentId || 'agent'), lane: 'active', history: (existing && existing.history) || [], automation: { kind: 'routine', id: run.cronJobId || '', name: run.cronJobName || run.title || 'Routine' } });
        const ws = Workstreams.get(sid);
        if (!ws) continue;
        const loaded = await fetchTranscript(ws.agentId, sid, Object.assign({ runId: runId }, opts));
        foldTurns(ws, loaded.turns, outcome, run.error || run.reason, loaded.fetchOk, run.ts, loaded);   // run.ts = real end time, never boot time
        if (hasCh()) Channels.end(sid);   // a backfilled run is DONE → clear any wedged busy/running state
      }
      await healUnreadable(options);   // sessions restored with only a report line get their real output now
      refreshRail();
      persist();
    } finally { backfilling = false; }
  }

  // ---- App bridges (fail-soft: the module still forms sessions even if a bridge is missing) -----
  function refreshRail() { try { if (hasApp() && App.refreshRail) App.refreshRail(); } catch (_) {} }
  function persist() { try { if (hasApp() && App.persist) App.persist(); } catch (_) {} }

  // ---- U.bus wiring (read-only) ----------------------------------------------------------------
  function onFire(p) {
    if (!p || !p.runId) return;
    let job = routineFor(p.jobId);
    if (!job && p.jobId) {
      // unknown routine → refresh the catalogue, then (re)seed the session's title once names arrive.
      loadRoutines().then(() => { const j = routineFor(p.jobId); const ws = Workstreams.get && Workstreams.get(streamOf(p.runId)); if (j && ws && (ws.title === 'Routine' || !ws.title)) { ws.title = j.name || 'Routine'; if (ws.agentId === 'agent' && j.agentId) ws.agentId = j.agentId; if (!ws.history.length && j.prompt) ws.history.push({ role: 'user', content: j.prompt }); refreshRail(); persist(); } });
    }
    beginSession(p.runId, Object.assign({ id: p.jobId || '' }, job || {}));
  }
  function onResult(p) {
    if (!p || !p.runId) return;
    completeSession(p.runId, p.outcome, p.reason);
  }

  function init() {
    if (!wired && hasU()) {
      wired = true;
      U.bus.on('cron.fire', onFire);
      U.bus.on('cron.result', onResult);
    }
    // backfill after boot; delayed so the save load + rail have settled (mirrors ReturnStore's digest delay).
    // After backfill, reconcile any session the restored save left marked busy (a mid-run reload/SSE drop) — a
    // finished run gets folded + un-wedged; a still-live one arms the bounded poll.
    setTimeout(() => { backfill().then(() => { reconcileBusy(); armReconcilePoll(); }); }, 1400);
  }
  function reset() {
    routines = null;
    stopReconcilePoll();
    for (const list of healTimers.values()) for (const t of list) clearTimeout(t);
    healTimers.clear();
  }   // a fresh Commander re-reads the catalogue; sessions are cleared by Workstreams.reset()

  return { init, reset, _internals: { beginSession, completeSession, foldTurns, recordOutcome, outcomeOfRun, backfill,
    fetchTranscript, hasReadableOutput, loadRoutines, routineFor, validStream, streamOf, ownedRows, readableInTurns,
    ladderFor, toolActions, runReport, isSilentToken, healRun, healUnreadable, clearHeal } };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = { AutoSessions };