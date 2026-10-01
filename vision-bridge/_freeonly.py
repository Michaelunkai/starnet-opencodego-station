import io
p="see.py"
s=io.open(p,encoding="utf-8").read()

old = """# models proven to read images on THIS host, best first.
# qwen3.8-max is the reliable one; the deepseek vision build answers
# correctly but sometimes returns an empty body, so it stays as backup.
VISION_MODELS = [
    "qwen3.8-max",
    "deepseek-v4-flash-vision-exp",
]"""

new = '''# ---------------------------------------------------------------------------------
# FREE-MODELS-ONLY IS THE DEFAULT, AND IT IS ENFORCED.
#
# The host's genuinely free models - the only ids containing "free" - are BOTH BLIND.
# Measured three times each with a real image (a red field, a blue square, the text
# "BLUE42"); every single call returned an EMPTY body, never a wrong answer:
#     space-bunny-free        empty x3
#     longcat-2.5-preview-free empty x3
# An empty body is the worst possible failure for a verification tool: it is silent,
# so an agent could mistake it for "nothing to report" and ship unverified work.
#
# So `see` REFUSES to spend a non-free model unless the caller explicitly opts in with
# --paid. Without that flag it will only ever consider ids containing "free", and since
# none of those can see, it exits 5 and says so. That is the honest outcome: a
# free-models-only station cannot see its own UI, and no amount of prompt wording
# changes that.
# ---------------------------------------------------------------------------------
FREE_ONLY = True   # flipped by --paid

# Sighted models on this host, and what they COST. None of these ids contains "free".
PAID_VISION_MODELS = [
    "qwen3.8-max",                  # the reliable one
    "deepseek-v4-flash-vision-exp",  # answers correctly, sometimes returns an empty body
]

# The only free ids on this host. Listed so the refusal message can name them, and so
# --probe can demonstrate their blindness rather than merely asserting it.
FREE_MODELS = [
    "space-bunny-free",
    "longcat-2.5-preview-free",
]

def allowed_vision_models():
    return list(FREE_MODELS) if FREE_ONLY else list(FREE_MODELS) + list(PAID_VISION_MODELS)'''

assert old in s
s = s.replace(old, new, 1)

s = s.replace('''# Tried only if every proven model fails. BLIND models are deliberately NOT listed:
# a text-only model handed an image does not error, it invents a plausible answer
# ("no screenshot is visible") that reads like a real verdict. A blind model is worse
# than no model, so the bridge only ever asks models that have actually proven sight.
FALLBACK_MODELS = [
    "minimax-m3",
]''',
'''# BLIND models are deliberately NOT listed: a text-only model handed an image does not
# error, it invents a plausible answer ("no screenshot is visible") that reads like a
# real verdict. A blind model is worse than no model, so the bridge only ever asks a
# model that has actually proven sight.''', 1)

s = s.replace("    models = VISION_MODELS + FALLBACK_MODELS\n",
              "    models = allowed_vision_models()\n", 1)
s = s.replace("    order = ([args.model] if args.model else []) + VISION_MODELS + FALLBACK_MODELS\n",
              "    order = ([args.model] if args.model else []) + allowed_vision_models()\n", 1)

s = s.replace('''    ap.add_argument("--model", help="force one vision model")''',
'''    ap.add_argument("--model", help="force one vision model")
    ap.add_argument("--paid", action="store_true",
                    help="permit a NON-free vision model. Off by default: the only free "
                         "models on this host are blind, so without this flag see exits 5.")''', 1)

s = s.replace("    args = ap.parse_args()\n",
              "    args = ap.parse_args()\n\n    if args.paid:\n        global FREE_ONLY\n        FREE_ONLY = False\n", 1)

s = s.replace('''    print("NO SIGHTED MODEL AVAILABLE on this host.", file=sys.stderr)
    for m, e in errors:
        print("  %-34s %s" % (m, e), file=sys.stderr)
    return 5''',
'''    if FREE_ONLY:
        print("NO SIGHTED FREE MODEL. This is a hardware fact, not a bug:", file=sys.stderr)
        print("  every free model on this host is text-only:", file=sys.stderr)
        for m in FREE_MODELS:
            print("    %-32s (blind - returns an empty body for any image)" % m, file=sys.stderr)
        print("", file=sys.stderr)
        print("  So a free-models-only run CANNOT visually verify a UI. I will not claim", file=sys.stderr)
        print("  otherwise, and I will not quietly spend a paid model to fake it.", file=sys.stderr)
        print("  Re-run with --paid to allow a sighted non-free model.", file=sys.stderr)
        return 5
    print("NO SIGHTED MODEL AVAILABLE on this host (--paid was allowed).", file=sys.stderr)
    for m, e in errors:
        print("  %-34s %s" % (m, e), file=sys.stderr)
    return 5''', 1)

io.open(p,"w",encoding="utf-8",newline="").write(s)
print("free-only guard installed; --paid is the explicit opt-in")
