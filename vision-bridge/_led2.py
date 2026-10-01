import json, io
p = r"C:\Users\Admin\.config\opencode\OpenCode-skills\bunny\tree\team_ledger.json"
d = json.load(io.open(p, encoding="utf-8-sig"))
for s in d["slots"]:
    if s.get("slot") == 2:
        s["agentId"] = "4c5a486a-ccd9-41f3-bbfc-a5ebf679d1eb"
        s["assignment"] = "finish attribution on last four chat paths (replacement for a hard-looping worker)"
        s["state"] = "running"
d["errorLedger"] = [{
    "slot": 2,
    "agentId": "5963e069-5312-4233-b938-dffed76793cc",
    "error": "Worker hard-looped: three consecutive turns each terminated mid-sentence on the identical fragment 'Now wire both producers through those helpers:'. No completion, no evidence.",
    "rootCause": "space-bunny-free entered a repeating plan-fragment loop when asked to BOTH finish a wiring refactor AND apply a large multi-site edit list in one turn; the turn budget was consumed restating the plan.",
    "permanentFix": "Manager completed the core work directly (NOVA prefix, STATION fail-safe render fallback, agentId on persistPartial/markStoppedTurn/in-band+thrown error rows), then created a REPLACEMENT on a single bounded site list. Standing rule for this model: ONE bounded edit list per turn.",
    "replacement": "4c5a486a-ccd9-41f3-bbfc-a5ebf679d1eb",
    "reproduces": "no"
}]
d["managerIntegration"] = {
    "allJsParse": "0 failures (index.js, chat.js, world.js, app.js, worldmodel.js, autosessions.js, leftrail.js, prepare-opencodego-station.js)",
    "launcherParseErrors": 0,
    "peakConcurrentCrew": 8,
    "freeModelsHaveVision": "YES - space-bunny-free and longcat-2.5-preview-free both read a test image correctly",
    "visionBridge": "C:\\Users\\Admin\\bin\\see.cmd",
    "globalRule": "opencode.json instructions[0] = VISUAL VERIFICATION IS MANDATORY"
}
json.dump(d, io.open(p, "w", encoding="utf-8"), indent=2)
print("ledger updated. slot2=%s  errorRows=%d  slots=%d" % (
    [s["agentId"] for s in d["slots"] if s.get("slot")==2][0], len(d["errorLedger"]), len(d["slots"])))
