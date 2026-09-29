'use strict';
// prepare-opencodego-station.js — writes the full team + brain config into the on-disk
// StarNet save so the browser resumes with every agent ready on first load.
// Designed to run BEFORE the sidecar starts (offline).

const fs = require('node:fs');
const path = require('node:path');

const WORKSPACE = path.join(process.env.LOCALAPPDATA, 'StarNet', 'opencodego', 'workspace');
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

// ---- clean stale station state so the station boots with no leftover errors ----
// A previous session's failed runs ("no model selected", "out of credit") live in the chat history,
// the run ledger and the transcript store; left in place they greet the Commander as if the station
// were still broken. The station is re-prepared from a known-good config, so those are cleared here.
let clearedWorkstreams = 0;
for (const ws of (Array.isArray(save.doc.workstreams) ? save.doc.workstreams : [])) {
  if (Array.isArray(ws.history) && ws.history.length) clearedWorkstreams++;
  ws.history = [];
  ws.runIds = [];
  ws.deliverables = [];
  ws.lastRunOk = null;
  ws.lastModel = null;
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