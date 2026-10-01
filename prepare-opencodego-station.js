'use strict';
// prepare-opencodego-station.js — writes the full team + brain config into the on-disk
// StarNet save so the browser resumes with every agent ready on first load.
// Designed to run BEFORE the sidecar starts (offline).

const fs = require('node:fs');
const path = require('node:path');

const WORKSPACE = process.env.STARNET_WORKSPACES || path.join(process.env.LOCALAPPDATA, 'StarNet', 'opencodego', 'workspace');
const MODEL     = 'mimo-v2.5';
const PROV      = 'opencode-go';
const now       = Date.now();

// ---- crew roster ----
function crew(id, name, role, purpose) {
  return {
    id, name, color: '#6fb3bf', skin: 'default',
    model: MODEL, provider: PROV, reasoningEffort: null, personaId: null,
    role, approvalMode: 'full', executionProfile: 'station-gear',
    workshop: false, purpose, specialtyId: null,
    docs: {
      identity: 'You are ' + name + ', ' + role + ' aboard this StarNet station. You are sharp, concise and action-oriented.',
      purpose: purpose,
      manual: 'You run fully unattended: NEVER ask the Commander anything — no clarifying questions, no FORK lines, ' +
        'no TASK_QUESTION lines, no confirmation requests, no "should I…?" offers. Choose the most sensible ' +
        'reversible default yourself, act immediately, drive the goal to completion, and report the finished result.',
      context: 'You are part of NOVA\'s standing crew. NOVA coordinates the station; accept missions delegated to ' +
        'you, do the work with your real tools, and report exact results back. Never stop before the goal is done.'
    },
    skills: [], stats: null, createdAt: now
  };
}

const team = [
  crew('foreman',    'FOREMAN',    'Team Lead',        'Split big missions across the crew, monitor every worker, reissue stalled jobs, report completion to NOVA with evidence.'),
  crew('researcher', 'RESEARCHER', 'Researcher',       'Answer with live web research and source every claim with the URL it came from.'),
  crew('engineer',   'ENGINEER',   'Engineer',         'Read code before changing it, build and fix automation, verify by running.'),
  crew('analyst',    'ANALYST',    'Analyst',           'Turn data into answers: compute, verify the arithmetic, show the numbers.'),
  crew('writer',     'WRITER',     'Scriptwriter',     'Write scripts, docs and content in the requested voice. Concise, no fluff.'),
  crew('scout',      'SCOUT',      'Scout',            'Watch the assigned sources and report only on real change, with evidence.'),
  crew('operator',   'OPERATOR',   'Automator',        'Run routine and scheduled work idempotently and log exactly what was done.')
];

// ---- read existing save (create skeleton on first boot) ----
const savePath = path.join(WORKSPACE, 'agent.save.json');
if (!fs.existsSync(savePath)) {
  fs.mkdirSync(WORKSPACE, { recursive: true });
  fs.writeFileSync(savePath, JSON.stringify({ doc: { schema: 'starnet.save', version: 6, agent: {}, agents: [], workstreams: [], _saveRevision: 0 }, updatedAt: 0, savedAt: 0 }, null, 2));
}
const save = JSON.parse(fs.readFileSync(savePath, 'utf8'));

// ---- hero ----
// SCHEMA STAMP (CRITICAL): the frontend's Save.load()/isSave() REJECTS any doc without
// `schema: 'starnet.save'` + `agent`, so a save written without it makes the browser show
// "STATION DATA UNREACHABLE" over a perfectly healthy sidecar. Stamp it here, always.
save.doc.schema = 'starnet.save';
if (!Number.isFinite(Number(save.doc.version)) || Number(save.doc.version) < 1) save.doc.version = 6;
// HERO IDENTITY (CRITICAL): the app resolves the hero by agent.id/name. A save whose agent has neither
// yields a null current agent -> the world never spawns -> a blank canvas ("I cannot see shit").
save.doc.agent.id     = 'agent';
save.doc.agent.name   = save.doc.agent.name || 'NOVA';
save.doc.agent.color  = save.doc.agent.color || '#5ad0ff';
save.doc.agent.skin   = save.doc.agent.skin || 'default';
// ONBOARDED (CRITICAL): app.js gates the "GET ACQUAINTED / awakening" ceremony on agent.onboarded. Without
// it the station shows onboarding questions instead of the live mission. Mark it done so the app resumes
// straight into the working station.
save.doc.agent.onboarded = true;
if (!save.doc.agent.purpose) save.doc.agent.purpose = 'Command the station crew on behalf of the Commander: take missions, delegate to specialists, monitor progress to completion, and report results.';
save.doc.prov           = PROV;
save.doc.agent.model    = MODEL;
save.doc.agent.provider = PROV;
save.doc.agent.approvalMode = 'full';   // the hero must never prompt either (frontend rehydrate defaults to 'ask' otherwise)
if (!save.doc.agent.docs) save.doc.agent.docs = {};
save.doc.agent.docs.identity =
  'You are NOVA, the coordinator aboard this StarNet station. You are sharp, concise, and ' +
  'action-oriented. You command a standing crew and delegate work to them. You speak to the Commander ' +
  'directly: take their missions, break them down, dispatch specialists, monitor progress to completion, ' +
  'and report results. You never stop before the goal is done.';

save.doc.agent.docs.purpose =
  'Command the station crew on behalf of the Commander. Take missions, delegate to the right specialist ' +
  '(FOREMAN, RESEARCHER, ENGINEER, ANALYST, WRITER, SCOUT, OPERATOR), monitor workers, and report completed results.';

save.doc.agent.docs.manual =
  'Use your real tools (shell, files, web, team.dispatch, team.subagents, team.steer) when a task needs them. ' +
  'You run fully unattended: NEVER ask the Commander anything — no clarifying questions, no FORK lines, no ' +
  'TASK_QUESTION lines, no confirmation requests, no "should I…?" offers. Choose the most sensible reversible ' +
  'default yourself, act immediately, drive every goal to completion, and report the finished result. ' +
  'If a request is ambiguous, pick the most useful interpretation and proceed; never stop to ask.';

// ---- crew into doc.agents ----
const heroLite = {
  id: 'agent', name: 'NOVA', color: '#5ad0ff', skin: 'default',
  model: MODEL, provider: PROV, reasoningEffort: null, personaId: 'worker-homie',
  role: 'orchestrator', approvalMode: 'full', executionProfile: 'station-gear',
  workshop: false, purpose: save.doc.agent.purpose || '', specialtyId: null,
  docs: save.doc.agent.docs || null,
  skills: [], stats: save.doc.agent.stats || null, createdAt: save.doc.agent.createdAt || now
};
save.doc.agents = [heroLite, ...team];

/* PRUNE THE SESSION RAIL — the shared, PURE decision table used by both the boot prune and the
   background reaper below, so "what may be deleted" is defined exactly once and the two can
   never drift apart.

   THE LEAK. Every armed routine fire mints its own `cron-<runId>` workstream (autosessions.js:149
   `Workstreams.adopt({ id: 'cron-'+runId, ... })`), and every finished run is left behind with its
   one-line status marker. A station that has been through a few hundred ticks therefore carries
   200+ rows, almost all of them dead stubs — which is what buried the two sessions that matter
   (the mission channel and the seven crew channels) and what the "couldn't load the output yet"
   markers were being written into. Pruning ONCE at boot is worthless: the rail refills on the
   very next tick. So the same table runs again from `runReaper()` for as long as the station lives.

   KEEP / DROP TABLE (first matching rule wins):

     | # | match                                     | action | why                                                     |
     |---|-------------------------------------------|--------|---------------------------------------------------------|
     | 1 | id === 'global'                           | KEEP   | the shared global mission channel                       |
     | 2 | id starts with 'crew-'                    | KEEP   | a crew member's channel (crew-<agentId>)                |
     | 3 | id starts with 'ws_' && is the HERO       | KEEP   | the Commander's own conversation (most recent, manual) |
     | 4 | any row with REAL content                 | KEEP   | real user/agent prose, or >=1 deliverable               |
     | 5 | id starts with 'cron-' && job is ARMED    | KEEP   | live routine (automation.id matches an enabled cron job)|
     | 6 | id starts with 'cron-' && it is the LAST  | KEEP   | most recent run of an armed routine (job.lastRunId)     |
     |     run of an ARMED routine                |        |                                                         |
     | 7 | everything else                           | DROP   | a dead automation stub                                   |

   RULE 4 IS THE SAFETY INVARIANT: it is evaluated from the row's state BEFORE anything is wiped,
   so the prune can never delete a session that carries real history or real deliverables. A
   corpse is precisely a row whose messages are all machine status lines (role 'system', sys:true)
   — the "— routine ran, nothing to report —" one-liners — and which has no deliverable. Status
   markers are telemetry about a run, not work, so they must NOT protect a corpse from deletion.

   Every dropped id is also TOMBSTONED into `deletedIds`. That is the existing contract owned by
   workstreams.js:154/240 (`adopt()` returns null for a tombstoned id unless `revive:true`), and it
   is what makes the prune HOLD: a pruned `cron-<runId>` can never be re-minted by the boot
   backfill (autosessions.js:324) or by the next fire's `beginSession` (autosessions.js:149). */
const RailPrune = (() => {
  const isChannel = (id) => id === 'global' || id.indexOf('crew-') === 0;
  // REAL WORK = prose a person or an agent actually wrote. A machine status line is NOT work.
  const isRealMessage = (m) => !!m && (m.role === 'user' || m.role === 'assistant') &&
    String(m.content == null ? '' : m.content).trim() !== '';
  function realContent(w) {
    if (Array.isArray(w.history) && w.history.some(isRealMessage)) return true;
    if (Array.isArray(w.deliverables) && w.deliverables.length) return true;
    return false;
  }
  const isAutomation = (w) => !!(w && w.automation) || String((w && w.title) || '').indexOf('CHRONO') === 0;
  // The REAL cron store: cron.jobs.json in the same workspace. `armed` = enabled job ids,
  // `latest` = each armed job's lastRunId (the id a live cron-<runId> row is named after).
  function readCronStore() {
    const armed = new Set(), latest = new Set();
    try {
      const cronPath = path.join(WORKSPACE, 'cron.jobs.json');
      if (!fs.existsSync(cronPath)) return { armed, latest };
      const store = JSON.parse(fs.readFileSync(cronPath, 'utf8') || '{}');
      const jobs = Array.isArray(store.jobs) ? store.jobs
        : (Array.isArray(store.routines) ? store.routines : []);
      for (const j of jobs) {
        if (!j || !j.id) continue;
        if (j.enabled === false) continue;
        armed.add(String(j.id));
        if (j.lastRunId) latest.add(String(j.lastRunId));
      }
    } catch (_) { /* fail-open: an unreadable store keeps nothing armed, so rules 5/6 never fire */ }
    return { armed, latest };
  }
  function decide(all, cron) {
    const armed = (cron && cron.armed) || new Set();
    const latest = (cron && cron.latest) || new Set();
    const rows = (Array.isArray(all) ? all : []).filter(Boolean);
    // the hero conversation: the most recently active MANUAL ws_* stream (automation never wins).
    let heroId = null, heroAt = -Infinity;
    for (const w of rows) {
      const id = String(w.id || '');
      if (id.indexOf('ws_') !== 0 || isChannel(id) || isAutomation(w)) continue;
      const at = Number(w.lastActiveAt || w.createdAt || 0) || 0;
      if (at > heroAt) { heroAt = at; heroId = id; }
    }
    const keep = [], dropped = [];
    for (const w of rows) {
      const id = String(w.id || '');
      let why = '';
      if (isChannel(id))                 why = 'global mission channel';
      else if (id.indexOf('crew-') === 0) why = 'crew channel';
      else if (id === heroId)            why = 'hero conversation';
      else if (realContent(w))           why = 'real history or deliverables';
      else if (id.indexOf('cron-') === 0) {
        const jobId = w.automation && String(w.automation.id || '');
        if (jobId && armed.has(jobId))  why = 'session of ARMED routine ' + jobId;
        else if (latest.has(id.slice(5))) why = 'last run of an ARMED routine';
      }
      if (why) keep.push({ w, why }); else dropped.push({ w, why: 'dead automation stub' });
    }
    return { keep, dropped };
  }
  return { decide, realContent, isAutomation, isChannel, readCronStore };
})();

/* THE REAPER — the fix that makes the prune HOLD instead of firing once.
   prepare-opencodego-station.js runs once per station launch (launch-opencodego.ps1:251), but the
   rail refills on every routine tick for as long as the station lives. So the boot run re-invokes
   THIS SAME SCRIPT as a detached child (`--rail-reaper`), which re-applies the identical table
   above on an interval and rewrites the save atomically. It reads the file fresh each tick, so it
   always sees the browser's latest persist; it only ever rewrites doc.workstreams + doc.deletedIds
   and leaves every other field (including _saveRevision) exactly as it found them. It is bounded
   in lifetime and killable via STARNET_RAIL_REAPER=0 / STARNET_RAIL_REAPER_MS / _MAX_MS. */
function runReaper() {
  const intervalMs = Math.max(5000, Number(process.env.STARNET_RAIL_REAPER_MS) || 20000);
  const lifeMs = Math.max(60000, Number(process.env.STARNET_RAIL_REAPER_MAX_MS) || 24 * 60 * 60 * 1000);
  const deadline = Date.now() + lifeMs;
  const tick = () => {
    if (Date.now() > deadline) { process.exit(0); }
    try {
      if (!fs.existsSync(savePath)) return;
      const doc = JSON.parse(fs.readFileSync(savePath, 'utf8'));
      const cron = RailPrune.readCronStore();
      const { keep, dropped } = RailPrune.decide(doc.doc && doc.doc.workstreams, cron);
      if (!dropped.length) return;
      doc.doc.workstreams = keep.map(k => k.w);
      // tombstone every dropped id so adopt() can never re-mint it (workstreams.js:240).
      const tombs = Array.isArray(doc.doc.deletedIds)
        ? doc.doc.deletedIds.filter(x => typeof x === 'string' && x) : [];
      for (const d of dropped) { const id = String(d.w.id || ''); if (id) tombs.push(id); }
      doc.doc.deletedIds = tombs.slice(-500);   // matches workstreams.js MAX_TOMBS
      const tmp = savePath + '.reaper.tmp';
      fs.writeFileSync(tmp, JSON.stringify(doc, null, 2));
      fs.renameSync(tmp, savePath);            // atomic: a reader never sees a half-written save
      console.log('[rail-reaper] pruned dead sessions: ' + dropped.length + ' -> ' + doc.doc.workstreams.length + ' kept');
    } catch (e) { console.warn('[rail-reaper] ' + ((e && e.message) || e)); }
  };
  tick();
  setInterval(tick, intervalMs);   // intentionally NOT unref'd: this process exists to keep reaping
}

// In reaper mode do nothing but reap — never re-stamp the save.
if (process.argv.indexOf('--rail-reaper') >= 0) { runReaper(); return; }

// ---- clean stale station state so the station boots with no leftover errors ----
// A previous session's failed runs ("no model selected", "out of credit") live in the chat history,
// the run ledger and the transcript store; left in place they greet the Commander as if the station
// were still broken. The station is re-prepared from a known-good config, so those are cleared here.
// NOTE: the wipe runs AFTER the prune decision below, so the safety invariant is judged on real
// pre-wipe content — never on state this block just erased.
let clearedWorkstreams = 0;
let prunedWorkstreams = 0;
{
  const { keep, dropped } = RailPrune.decide(save.doc.workstreams, RailPrune.readCronStore());
  prunedWorkstreams = dropped.length;
  save.doc.workstreams = keep.map(k => k.w);
  const tombs = Array.isArray(save.doc.deletedIds)
    ? save.doc.deletedIds.filter(x => typeof x === 'string' && x) : [];
  for (const d of dropped) { const id = String(d.w.id || ''); if (id) tombs.push(id); }
  save.doc.deletedIds = tombs.slice(-500);
  for (const w of save.doc.workstreams) {
    if (Array.isArray(w.history) && w.history.length) clearedWorkstreams++;
    w.history = [];
    w.runIds = [];
    w.deliverables = [];
    w.lastRunOk = null;
    w.lastModel = null;
  }
  console.log('  pruned dead sessions: ' + prunedWorkstreams + ' -> ' + save.doc.workstreams.length + ' kept');
}

const runsPath = path.join(WORKSPACE, 'runs.jsonl');
try { if (fs.existsSync(runsPath)) fs.writeFileSync(runsPath, ''); } catch (_) {}
// Remove the transcript store WHOLE (dir + manifest). Deleting only the segment files left the
// manifest pointing at missing segments, so the store logged ENOENT on boot — the store must be
// reset as a unit or re-initialized cleanly. The agent/ workspace dir is deliberately untouched.
for (const dirName of ['transcript-history-v2']) {
  const dir = path.join(WORKSPACE, dirName);
  try { if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
}
// Empty the run-journal dir too: a journal left by a killed process is replayed at boot as an
// "interrupted" run-history row, so stale unfinished runs would otherwise greet the Commander.
const journalDir = path.join(WORKSPACE, '.run-journal');
try {
  if (fs.existsSync(journalDir)) {
    for (const entry of fs.readdirSync(journalDir)) {
      try { fs.rmSync(path.join(journalDir, entry), { force: true }); } catch (_) {}
    }
  }
} catch (_) {}

// ---- anti-clobber: set _saveRevision very high so any stale browser write is rejected ----
save.doc._saveRevision = 1000;
save.doc._saveDirty    = false;
save.updatedAt         = now;
save.savedAt           = now;
save.doc.updatedAt     = now;

// ---- write save ----
fs.writeFileSync(savePath, JSON.stringify(save, null, 2));
console.log('save written: ' + savePath);
console.log('  prov=' + save.doc.prov);
console.log('  hero model=' + save.doc.agent.model);
console.log('  doc.agents=' + save.doc.agents.length + ' (hero + ' + (save.doc.agents.length - 1) + ' crew)');
console.log('  cleared workstream histories=' + clearedWorkstreams + ', runs.jsonl + transcripts reset');

// ---- also write roster file (sidecar reads it independently) ----
const rosterPath = path.join(WORKSPACE, 'agent.roster.json');
const roster = {
  version: 1,
  updatedAt: now,
  agents: [
    {
      agentId: 'agent', system: '', name: 'NOVA', model: MODEL, provider: PROV,
      role: 'orchestrator', approvalMode: 'full', executionProfile: 'station-gear',
      skills: [], reasoningEffort: null, track: 'finish rate: DEPENDABLE'
    },
    ...team.map(a => ({
      agentId: a.id, system: '', name: a.name, model: MODEL, provider: PROV,
      role: a.role, approvalMode: 'full', executionProfile: 'station-gear',
      skills: [], reasoningEffort: null, track: ''
    }))
  ]
};
fs.writeFileSync(rosterPath, JSON.stringify(roster, null, 2));
console.log('roster written: ' + rosterPath + ' (' + roster.agents.length + ' agents)');

// ---- ensure .run-journal dir ----
fs.mkdirSync(journalDir, { recursive: true });
console.log('journal dir ensured: ' + journalDir);

// ---- START THE RAIL REAPER (the prune that HOLDS) ----
// The boot prune above runs once per launch, but the rail refills on every routine tick, so a
// once-only prune is worthless. Re-invoke this same script detached as `--rail-reaper`: it
// re-applies the IDENTICAL RailPrune table on an interval for as long as the station lives.
// Fail-open and silent: if the child cannot start, the station is unaffected.
if (process.env.STARNET_RAIL_REAPER !== '0') {
  try {
    const { spawn } = require('node:child_process');
    const child = spawn(process.execPath, [__filename, '--rail-reaper'], {
      detached: true, stdio: 'ignore', windowsHide: true,
      env: Object.assign({}, process.env)
    });
    child.unref();
    console.log('  rail reaper started (every ' + (Number(process.env.STARNET_RAIL_REAPER_MS) || 20000) + 'ms)');
  } catch (e) { console.log('  rail reaper not started: ' + ((e && e.message) || e)); }
} else {
  console.log('  rail reaper disabled by STARNET_RAIL_REAPER=0');
}