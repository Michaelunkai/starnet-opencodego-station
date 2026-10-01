import json, io
p = r"C:\Users\Admin\.config\opencode\OpenCode-skills\bunny\tree\team_ledger.json"
d = json.load(io.open(p, encoding="utf-8-sig"))
for s in d["slots"]:
    if s.get("n") == 2:
        s["agent"] = "4c5a486a-ccd9-41f3-bbfc-a5ebf679d1eb"
        s["assignment"] = "finish attribution on last four chat paths (replacement)"
d["error_ledger"] = [{
    "slot": 2,
    "agent": "5963e069-5312-4233-b938-dffed76793cc",
    "error": "Worker hard-looped: three consecutive turns all terminated mid-sentence on the identical fragment 'Now wire both producers through those helpers:'. No completion, no evidence.",
    "root_cause": "Free model (space-bunny-free) entered a repeating plan-fragment loop when asked to BOTH finish a wiring refactor AND apply a large multi-site edit list in one turn. The turn budget was consumed restating the plan.",
    "permanent_fix": "Manager completed the core work directly (NOVA prefix, STATION fail-safe fallback, agentId on persistPartial/markStoppedTurn/error rows), then created a REPLACEMENT agent on a single bounded site list. Standing rule for this model: ONE bounded edit list per turn, never 'finish the wiring AND apply these ten more edits'.",
    "replacement": "4c5a486a-ccd9-41f3-bbfc-a5ebf679d1eb",
    "reproduces": "no - the replacement carries a narrowed single-list brief"
}]
d["status"] = "RUNNING"
json.dump(d, io.open(p, "w", encoding="utf-8"), indent=2)
print("ledger ok: slot2=%s  error_rows=%d  slots=%d" % (d["slots"][1]["agent"], len(d["error_ledger"]), len(d["slots"])))
