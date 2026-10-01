import io
p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\app\chat.js"
s = io.open(p, encoding="utf-8").read()

old = """      const spoke = (m && m.agentId && typeof App !== 'undefined' && App.agentName) ? App.agentName(m.agentId) : null;"""
new = """      // WHEN THERE IS NO agentId, `row('agent', {who:null})` falls back to the FOCUSED agent's name, and
      // that is precisely how one crew member's words end up wearing ANOTHER agent's name badge. Fail safe
      // instead: a row with no recorded author is the STATION's, never an arbitrary agent's. Rows that
      // genuinely belong to the focused agent carry its own id and are already covered by the branch above.
      const spoke = (m && m.agentId && typeof App !== 'undefined' && App.agentName)
        ? App.agentName(m.agentId)
        : 'STATION';"""

assert old in s, "spoke line not found"
s = s.replace(old, new, 1)

# ---- the writers that set no author at all: give each the real agentId + prefix ----
# Each entry: (unique anchor line, the replacement that carries the author through).
fixes = [
  # persistPartial - a streaming partial of the focused agent's own reply
  ("""    const partial = { role: 'assistant', content: acc, ts: Date.now() };""",
   """    const partial = { role: 'assistant', content: acc, ts: Date.now(), agentId: attachAgentId ? attachAgentId() : undefined };"""),
  # markStoppedTurn
  ("""    stopped = { role: 'assistant', content: text, stopped: true, ts: Date.now() };""",
   """    stopped = { role: 'assistant', content: text, stopped: true, ts: Date.now(), agentId: attachAgentId ? attachAgentId() : undefined };"""),
]
applied = []
for old_f, new_f in fixes:
    if old_f in s:
        s = s.replace(old_f, new_f, 1)
        applied.append(old_f.strip()[:60])

# in-band / thrown errors and the final reply: find them by their distinctive prefixes
error_rows = [
  ("{ role: 'assistant', content: '\\u26a0 ' + msg, error: true }",
   "{ role: 'assistant', content: '\\u26a0 ' + msg, error: true, agentId: attachAgentId ? attachAgentId() : undefined }"),
]
for old_e, new_e in error_rows:
    n = s.count(old_e)
    if n:
        s = s.replace(old_e, new_e)
        applied.append("error row x%d" % n)

io.open(p, "w", encoding="utf-8", newline="").write(s)
print("applied:", applied)
