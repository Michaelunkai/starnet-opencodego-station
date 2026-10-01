import io, re
p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\app\chat.js"
s = io.open(p, encoding="utf-8").read()
# match the error row by shape, not by its (mojibake) literal prefix
pat = re.compile(r"(ws\.history\.push\(\{ role: 'assistant', content: '[^']*' \+ v\.userMessage, error: true, ts: Date\.now\(\))( \}\);)")
n = len(pat.findall(s))
s = pat.sub(r"\1, agentId: ws.agentId || 'agent'\2", s)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print("in-band error rows patched:", n)
