import io
p = r"F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet\frontend\css\panelchrome.css"
s = io.open(p, encoding="utf-8").read()
anchor = "/* hover: the status rail lights, no outer bloom (motion.css keeps its -1px lift) */"
add = """/* WHOLE-ROSTER COMPACT ROWS (2026-10-01).
   The rail caps itself to the rows that FIT, so an eight-person crew in a short column
   showed only four names and the other four were simply not there - which read as "the
   crew is missing" even though the counter said 7 WORKING. The cap is honest geometry and
   must stay (it is what lets the Commander drag the split), but the ROWS get tighter so a
   normal eight-agent crew fits whole without any scrolling, and when the roster genuinely
   cannot fit, .crew-more says so out loud instead of silently clipping the tail. */
.crew-row { margin: 1px 6px 0; padding: 2px 8px 3px; }
.crew-row .crew-name { font-size: 15px; line-height: 1.1; }
.crew-row .crew-status { font-size: 12px; line-height: 1.1; }
.crew-row .crew-room { font-size: 9.5px; }
.crew-row.working .crew-prog { margin-top: 2px; }
/* the honest overflow tell: rendered by leftrail.js when rows are still clipped */
#crew-more {
  display: block; margin: 4px 6px 0; padding: 3px 8px; font-size: 12px;
  letter-spacing: .5px; color: var(--ph-dim); text-align: center;
  border: 1px dashed var(--ph-faint); border-radius: 3px;
}
#crew-more[hidden] { display: none; }

"""
assert anchor in s
s = s.replace(anchor, add + anchor, 1)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print("compact roster rows + overflow tell added to panelchrome.css")
