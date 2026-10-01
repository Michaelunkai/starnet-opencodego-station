import io
# 1. add the overflow row to the DOM right after #crew
p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\index.html"
s = io.open(p, encoding="utf-8").read()
import re
m = re.search(r'(<ul[^>]*id="crew"[^>]*>)', s)
if m and 'crew-more' not in s:
    ins = m.group(1) + '\n      <li id="crew-more" hidden></li>'
    s = s[:m.start(1)] + ins + s[m.end(1):]
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    print("inserted #crew-more into index.html")
else:
    print("index.html: crew list not matched or already present")

# 2. teach leftrail.js to keep the tell honest
p2 = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\app\leftrail.js"
t = io.open(p2, encoding="utf-8").read()
old = "    ul.classList.toggle('shut', cap === 0);"
new = """    // NEVER CLIP THE CREW SILENTLY. If rows are still hidden below the cap, say how many:
    // a rail that quietly shows four of eight names reads as a broken crew, not a scrolled one.
    const more = document.getElementById('crew-more');
    if (more) {
      const shownCuts = cuts.filter(function (c) { return c <= cap + 0.5; }).length;
      const hidden = cuts.length - shownCuts;
      if (hidden > 0) {
        more.hidden = false;
        more.textContent = '\\u25bc ' + hidden + ' more below \\u2014 drag the rail seam to show all ' + cuts.length;
      } else {
        more.hidden = true;
        more.textContent = '';
      }
    }
    ul.classList.toggle('shut', cap === 0);"""
assert old in t
t = t.replace(old, new, 1)
io.open(p2, "w", encoding="utf-8", newline="").write(t)
print("leftrail.js: overflow tell wired")
