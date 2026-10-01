import io
p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\app\chat.js"
s = io.open(p, encoding="utf-8").read()

# Every one of these rows is the FOCUSED stream's own turn, so the focused agent is the
# truthful author. Recording it stops the render fallback from having to guess - and stops
# one agent's words from inheriting a DIFFERENT agent's badge on a later replay.
fixes = [
  ("ws.history.push({ role: 'assistant', content: text, stopped: true, ts: Date.now() });",
   "ws.history.push({ role: 'assistant', content: text, stopped: true, ts: Date.now(), agentId: ws.agentId || 'agent' });"),
  ("ws.history.push({ role: 'assistant', content: '? ' + v.userMessage, error: true, ts: Date.now() });",
   "ws.history.push({ role: 'assistant', content: '? ' + v.userMessage, error: true, ts: Date.now(), agentId: ws.agentId || 'agent' });"),
]
applied = []
for old_f, new_f in fixes:
    if old_f in s:
        s = s.replace(old_f, new_f, 1)
        applied.append(old_f[:70])
    else:
        applied.append("MISS: " + old_f[:70])

# persistPartial / markStoppedTurn bodies: find the row each one pushes
import re
def add_agent_to_row(src, funcname):
    i = src.find("function %s(" % funcname)
    if i < 0:
        return src, False
    j = src.find("\n  }", i)
    body = src[i:j]
    newbody = re.sub(r"(\{ role: 'assistant',[^}]*?ts: Date\.now\(\))( \})", r"\1, agentId: (ws && ws.agentId) || 'agent'\2", body, count=1)
    if newbody == body:
        return src, False
    return src[:i] + newbody + src[j:], True

for fn in ("persistPartial", "markStoppedTurn"):
    s, ok = add_agent_to_row(s, fn)
    applied.append("%s: %s" % (fn, "patched" if ok else "NO ROW MATCH"))

io.open(p, "w", encoding="utf-8", newline="").write(s)
for a in applied:
    print("  " + a)
