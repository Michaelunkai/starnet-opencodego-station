import io, re, sys

p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\app\chat.js"
s = io.open(p, encoding="utf-8").read()

start = "  const ACTIVITY_MAX = 400;"
end = "  try { wireActivity(); } catch (_) {}"

i = s.index(start)
j = s.index(end)
assert i > 0 and j > i, (i, j)

new = r'''  const ACTIVITY_MAX = 400;                 // hard cap on retained feed lines - the DOM stays bounded
  const ACTIVITY_REPEAT_MS = 25000;         // same agent + same words inside this window = a REPEAT
  const activitySeen = new Set();            // raw event ids, so a replayed frame never double-posts
  const activityRows = new Map();           // "agentId|text" -> the live row that owns that message
  let activityWired = false;

  // ---- ATTRIBUTION: the one thing that must never be missing --------------------
  const AGENT_LABEL = {
    agent: 'NOVA', researcher: 'RESEARCHER', analyst: 'ANALYST', engineer: 'ENGINEER',
    writer: 'WRITER', scout: 'SCOUT', operator: 'OPERATOR', foreman: 'FOREMAN'
  };
  function agentLabel(agentId) {
    const id = String(agentId || '').trim();
    if (!id) return 'STATION';
    if (AGENT_LABEL[id]) return AGENT_LABEL[id];
    return id.replace(/[_.]+/g, ' ').toUpperCase();
  }

  function activityDetail(args) {
    if (args == null) return '';
    let a = args;
    if (typeof a === 'string') { try { a = JSON.parse(a); } catch (_) { return String(a).slice(0, 80); } }
    if (!a || typeof a !== 'object') return String(a == null ? '' : a).slice(0, 80);
    const keys = ['query', 'url', 'path', 'file', 'filename', 'command', 'cmd', 'pattern', 'prompt',
                  'text', 'name', 'title', 'session', 'description', 'model', 'task', 'target'];
    for (const k of keys) {
      const v = a[k];
      if (typeof v === 'string' && v.trim()) {
        let t = v.trim().replace(/\s+/g, ' ');
        return t.length > 72 ? t.slice(0, 72) + '\u2026' : t;
      }
    }
    return '';
  }
  const ACTIVITY_VERB = {
    web_search: 'Searching the web', web_fetch: 'Fetching the page', browser: 'Browsing',
    fs_read: 'Reading a file', fs_write: 'Writing a file', fs_append: 'Appending to a file',
    fs_list: 'Listing files', fs_edit: 'Editing a file', fs_delete: 'Deleting a file',
    shell_exec: 'Running a command', shell_bg: 'Running a background command', shell_status: 'Checking command',
    team_dispatch: 'Dispatching the crew', team_spawn: 'Spawning a worker', team_subagents: 'Checking the crew',
    team_steer: 'Steering a worker', notebook_write: 'Writing notes', notebook_read: 'Reading notes',
    memory_search: 'Searching memory', image_generate: 'Generating an image', vision_analyze: 'Reading an image',
    deliverable_save: 'Saving the deliverable', session_list: 'Listing sessions', routine_run: 'Running a routine',
    skill_run: 'Running a skill'
  };
  function activityVerb(name) {
    const raw = String(name || '').trim();
    if (!raw) return 'Working';
    const key = raw.replace(/^mcp__[^_]+__/, '').replace(/[.\-\s]+/g, '_').toLowerCase();
    return ACTIVITY_VERB[key] || ('Using ' + raw.replace(/^mcp__[^_]+__/, '').replace(/[_.]+/g, ' ').toLowerCase());
  }
  // A tool RESULT must not restate the CALL - that is the same message twice. It reports
  // only the outcome delta the call line did not already carry.
  function activityOutcome(p) {
    const ok = p && (p.ok === true || p.ok === false) ? p.ok : null;
    const ms = p && typeof p.ms === 'number' ? p.ms : null;
    let out;
    if (ok === true) out = 'done';
    else if (ok === false) out = 'FAILED';
    else out = 'done';
    if (ms != null && ms >= 0) out += ' in ' + (ms >= 1000 ? (ms / 1000).toFixed(1) + 's' : Math.round(ms) + 'ms');
    return out;
  }

  // The mission feed belongs to the MISSION session (stream 'global') - that is the one chat where the
  // whole crew is visible together. It is broadcast there unconditionally, AND into whatever session the
  // Commander currently has open, so the feed is never invisible just because a group tab is focused.
  function activityTargets() {
    const out = [];
    const seen = new Set();
    const push = (w) => { if (w && !seen.has(w.id)) { seen.add(w.id); out.push(w); } };
    try { if (typeof Channels !== 'undefined' && Channels.get) push(Channels.get('global')); } catch (_) {}
    try { if (typeof Workstreams !== 'undefined' && Workstreams.list) {
            for (const w of Workstreams.list()) if (w && (w.stream === 'global' || w.id === 'global')) push(w);
          } } catch (_) {}
    push(activeWs);
    return out;
  }

  function paintRow(row) {
    for (const w of activityTargets()) {
      try {
        const h = w.history || [];
        for (let k = 0; k < h.length; k++) {
          if (h[k] && h[k].id === row.id) { h[k] = row; break; }
        }
        w.history = h;
        if (w === activeWs) renderHistory(w);
      } catch (_) {}
    }
  }

  function pushActivity(agentId, text, kind) {
    const who = String(agentId || '').trim();
    if (!who) return;
    const label = agentLabel(who);
    const body = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
    if (!body) return;

    // ---- NEVER SAY THE SAME THING TWICE -------------------------------------
    // The identity of a message is (author, words). A second identical message from
    // the same author inside the window is not news: it collapses into a counter on
    // the row that already said it, so the chat never repeats itself.
    const key = who + '|' + body;
    const now = Date.now();
    const prior = activityRows.get(key);
    if (prior && (now - prior.ts) < ACTIVITY_REPEAT_MS) {
      prior.count = (prior.count || 1) + 1;
      prior.ts = now;
      prior.content = '[' + label + '] ' + body + '  \u00d7' + prior.count;
      paintRow(prior);
      return;
    }

    const line = '[' + label + '] ' + body;
    const row = {
      id: 'act-' + now.toString(36) + '-' + Math.random().toString(36).slice(2, 8),
      role: kind === 'end' ? 'assistant' : 'tool',
      agentId: who,
      agentLabel: label,
      content: line,
      count: 1,
      ts: now,
      live: true
    };
    activityRows.set(key, row);
    if (activityRows.size > ACTIVITY_MAX * 4) {
      const entries = Array.from(activityRows.entries()).sort(function (a, b) { return a[1].ts - b[1].ts; });
      for (let n = 0; n < entries.length / 4; n++) activityRows.delete(entries[n][0]);
    }
    if (activitySeen.size > ACTIVITY_MAX * 4) activitySeen.clear();

    for (const w of activityTargets()) {
      try {
        w.history = (w.history || []).concat([row]);
        if (w.history.length > ACTIVITY_MAX) w.history = w.history.slice(-ACTIVITY_MAX);
        if (w === activeWs) renderHistory(w);
      } catch (_) {}
    }
  }

  function wireActivity() {
    if (activityWired) return;
    if (typeof U === 'undefined' || !U.bus) return;
    activityWired = true;
    const evKey = (kind, p) => kind + '|' + (p && (p.eventId || p.id) || '') + '|' +
      (p && p.agentId || '') + '|' + (p && p.name || '') + '|' + (p && p.callId || '');
    const once = (key) => {
      if (!key) return true;
      if (activitySeen.has(key)) return false;
      activitySeen.add(key);
      return true;
    };
    const detailOf = (p) => activityDetail(p.argsSummary != null ? p.argsSummary : p.args);

    U.bus.on('agent.tool_call', p => {
      if (!p || !p.agentId) return;
      if (!once(evKey('call', p))) return;
      const d = detailOf(p);
      pushActivity(p.agentId, activityVerb(p.name) + (d ? ' \u2014 "' + d + '"' : ''), 'call');
    });
    U.bus.on('agent.tool_result', p => {
      if (!p || !p.agentId) return;
      if (!once(evKey('res', p))) return;
      pushActivity(p.agentId, activityOutcome(p), 'result');
    });
    U.bus.on('agent.run.start', p => {
      if (!p || !p.agentId) return;
      if (!once(evKey('start', p))) return;
      pushActivity(p.agentId, 'started a run', 'start');
    });
    U.bus.on('agent.run.end', p => {
      if (!p || !p.agentId) return;
      if (!once(evKey('end', p))) return;
      pushActivity(p.agentId, p.reason ? 'run ended (' + p.reason + ')' : 'run ended', 'end');
    });
  }
'''

s = s[:i] + new + s[j:]
io.open(p, "w", encoding="utf-8", newline="").write(s)
print("patched chat.js activity feed")
