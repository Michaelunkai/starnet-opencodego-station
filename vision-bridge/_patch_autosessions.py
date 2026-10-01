import io

p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\app\autosessions.js"
s = io.open(p, encoding="utf-8").read()

old = """    ws.history = next;
    // hybrid-honest: a real run fired \u2192 todo advances to active."""

new = """    // SAY IT ONCE. A crew of 8 routines ticking every 3 minutes used to stack one
    // "routine ran, nothing to report" line per routine per tick, burying the chat in
    // identical filler. Identical consecutive status markers now collapse into a single
    // line carrying an honest repeat count - the reader learns that N quiet ticks
    // happened instead of re-reading the same sentence N times.
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
      if (m.repeat && m.repeat > 1) m.content = String(m.content) + '  (\\u00d7' + m.repeat + ')';
    }
    ws.history = collapsed;
    // hybrid-honest: a real run fired \u2192 todo advances to active."""

assert old in s, "foldTurns tail not found"
s = s.replace(old, new, 1)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print("patched autosessions.js: status markers never repeat")
