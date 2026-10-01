import io, json, shutil, time, os

p = r"C:\Users\Admin\.config\opencode\opencode.json"
shutil.copyfile(p, p + ".bak-vision-%s" % time.strftime("%Y%m%d-%H%M%S"))

with io.open(p, encoding="utf-8") as fh:
    cfg = json.load(fh)

RULE = (
    "VISUAL VERIFICATION IS MANDATORY (2026-10-01). Most models on this host are TEXT-ONLY: a "
    "screenshot tool returns 'ERROR: Cannot read image (this model does not support image input)', "
    "so a blind model CANNOT see and must never claim it did. Every visual task goes through the "
    "global `see` command, which captures pixels (browser URL, real desktop monitor, or image file), "
    "sends them to a vision-capable model on the OpenCodeGo proxy, and returns TEXT - so it works "
    "identically for a blind model and a sighted one. HARD RULE: never report a visual result you did "
    "not read through `see`. If a screenshot tool told you it captured something and you did not then "
    "run `see`, you have seen nothing and must say so. To inspect a running app: "
    "`see --url http://127.0.0.1:8787/ --check C:\\Users\\Admin\\bin\\see-checks.json` (exit 0 only when "
    "every requirement passed). For any real desktop or window: `see --monitor`. For an image the user "
    "attached: find the file, then `see --file <path>`. `see --probe` shows which models can see right "
    "now. If `see` exits 5 (no sighted model reachable) report exactly that - 'I could not visually "
    "verify this' - and never paper over it. The `see` skill has full usage."
)

instructions = cfg.get("instructions") or []
if not isinstance(instructions, list):
    instructions = [str(instructions)]
# replace any earlier copy of this same rule so it can never stack up
instructions = [
    s for s in instructions
    if "VISUAL VERIFICATION IS MANDATORY" not in str(s)
]
instructions.insert(0, RULE)
cfg["instructions"] = instructions

with io.open(p, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)

print("global instructions count:", len(cfg["instructions"]))
print("rule installed at index 0, %d chars" % len(RULE))
