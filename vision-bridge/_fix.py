import io
p="see.py"
s=io.open(p,encoding="utf-8").read()

old_start = "# ---------------------------------------------------------------------------------\n# FREE-MODELS-ONLY IS THE DEFAULT, AND IT IS ENFORCED."
old_end   = "def allowed_vision_models():\n    return list(FREE_MODELS) if FREE_ONLY else list(FREE_MODELS) + list(PAID_VISION_MODELS)"
i = s.index(old_start); j = s.index(old_end) + len(old_end)

new = '''# ---------------------------------------------------------------------------------
# FREE-MODELS-ONLY IS THE DEFAULT, AND IT IS ENFORCED.
#
# Only ids containing "free" may be spent unless the caller passes --paid.
#
# MEASURED, AND THE FIRST MEASUREMENT WAS WRONG - the correction matters:
# a narrow probe ("reply with ONLY the text and the colour") made BOTH free models return
# an EMPTY body, which looked exactly like blindness. Re-tested fairly, on a real 1600x900
# dashboard screenshot, with the real inspection task:
#     space-bunny-free  -> 4/4 verdicts, every one of which independently MATCHES what
#                          deepseek-v4-flash-vision-exp reports from the same image
#                          ("7 WORKING", "1 IDLE", COMMS "online", "[WRITER] run ended").
# Two unrelated models agreeing on the same specifics from the same pixels is the real
# evidence, and it says the free model CAN see. The lesson recorded here: never conclude a
# model is blind from a single narrow prompt - an empty body is evidence of nothing.
#
# So the free path is the DEFAULT and it works. --paid exists only as an escape hatch.
# ---------------------------------------------------------------------------------
FREE_ONLY = True   # flipped by --paid

FREE_MODELS = [
    "space-bunny-free",           # the reliable free one
    "longcat-2.5-preview-free",   # free backup
]

# Sighted, but NOT free - refused unless --paid is given.
PAID_VISION_MODELS = [
    "qwen3.8-max",
    "deepseek-v4-flash-vision-exp",
    "minimax-m3",
]

def allowed_vision_models():
    return list(FREE_MODELS) if FREE_ONLY else list(FREE_MODELS) + list(PAID_VISION_MODELS)'''

s = s[:i] + new + s[j:]

s = s.replace('''    if FREE_ONLY:
        print("NO SIGHTED FREE MODEL. This is a hardware fact, not a bug:", file=sys.stderr)
        print("  every free model on this host is text-only:", file=sys.stderr)
        for m in FREE_MODELS:
            print("    %-32s (blind - returns an empty body for any image)" % m, file=sys.stderr)
        print("", file=sys.stderr)
        print("  So a free-models-only run CANNOT visually verify a UI. I will not claim", file=sys.stderr)
        print("  otherwise, and I will not quietly spend a paid model to fake it.", file=sys.stderr)
        print("  Re-run with --paid to allow a sighted non-free model.", file=sys.stderr)
        return 5
    print("NO SIGHTED MODEL AVAILABLE on this host (--paid was allowed).", file=sys.stderr)''',
'''    print("NO SIGHTED MODEL AVAILABLE. free-only is on, so only these were tried:", file=sys.stderr)
    for m in FREE_MODELS:
        print("    %-32s %s" % (m, dict(errors).get(m, "no answer")), file=sys.stderr)
    print("  Re-run with --paid to also allow a sighted non-free model.", file=sys.stderr)''', 1)

# a fair probe: the real task, not a one-word squeeze
s = s.replace('''                answer = ask_sighted(
                    m, probe_bytes,
                    "Reply with ONLY the text you see and the colour of the left "
                    "square. If you cannot see images reply NOVISION.",
                    timeout=90, max_tokens=60,
                )''',
'''                answer = ask_sighted(
                    m, probe_bytes,
                    "Look at this image. In ONE sentence, describe what you see: the "
                    "background colour, the colour and shape of the object on the left, "
                    "and any words printed on the right. If you genuinely cannot see "
                    "images, reply exactly NOVISION.",
                    timeout=120, max_tokens=200,
                )''', 1)

io.open(p,"w",encoding="utf-8",newline="").write(s)
print("free-first ordering + fair probe installed")
