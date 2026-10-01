import io

p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\app\chat.js"
s = io.open(p, encoding="utf-8").read()

old = """    const labeled = turns.map(t => {
      if (!t || (t.role !== 'assistant' && t.role !== 'tool' && t.role !== 'user')) return t;
      const who = String(t.agentId || '');
      if (isHeroTurn(who)) return t;
      const c = String(t.content == null ? '' : t.content);
      const tag = '[' + who.toUpperCase() + '] ';
      if (c.indexOf(tag) === 0) return t;
      return Object.assign({}, t, { content: tag + c });
    });"""

new = """    const labeled = turns.map(t => {
      if (!t || (t.role !== 'assistant' && t.role !== 'tool' && t.role !== 'user')) return t;
      const who = String(t.agentId || '');
      if (isHeroTurn(who)) return t;
      const c = String(t.content == null ? '' : t.content);
      // agentLabel() is the ONE name authority, shared with the live activity feed, so a turn and a
      // tool line from the same worker always read with the identical name.
      const tag = '[' + agentLabel(who) + '] ';
      if (c.indexOf(tag) === 0) return t;
      return Object.assign({}, t, { content: tag + c, agentLabel: agentLabel(who) });
    });
    // SAY IT ONCE: a crew worker that emits the same words twice (a re-asked question, a retried
    // step, a stock heartbeat line) must not stack up in the chat. The FIRST occurrence is kept
    // and later identical ones are dropped - the chat reads as news, not as an echo. Different
    // authors saying the same words are both kept: the author is part of a message's identity.
    const spokenRecently = new Set();
    const onceSaid = [];
    for (const t of labeled) {
      if (!t) { onceSaid.push(t); continue; }
      const c = String(t.content == null ? '' : t.content).replace(/\\s+/g, ' ').trim();
      if (!c) { onceSaid.push(t); continue; }
      const sig = String(t.agentId || '') + '\\u0000' + c.toLowerCase();
      if (spokenRecently.has(sig)) continue;
      spokenRecently.add(sig);
      if (spokenRecently.size > 4000) { const keep = Array.from(spokenRecently).slice(-2000); spokenRecently.clear(); for (const k of keep) spokenRecently.add(k); }
      onceSaid.push(t);
    }"""

assert old in s, "label block not found"
s = s.replace(old, new, 1)
s = s.replace("    const next = mergeCanonicalHistory(ws.history, labeled);",
              "    const next = mergeCanonicalHistory(ws.history, onceSaid);", 1)

io.open(p, "w", encoding="utf-8", newline="").write(s)
print("patched transcript attribution + say-once")
