import see, io, glob, os
# use the real dashboard capture we already have
src = sorted(glob.glob("shots\\cap-*.png"))[-1]
raw = open(src,"rb").read()
print("source:", os.path.basename(src), len(raw), "bytes")
from PIL import Image
for max_side in (1280, 1024, 896, 768):
    small = see.shrink(raw, max_side=max_side, quality=75)
    ok = 0; errs=[]
    for i in range(3):
        try:
            t = see.chat_vision("space-bunny-free", small,
                "How many agents does the crew list show as WORKING? One short sentence.",
                timeout=90, max_tokens=70)
            if t.strip():
                ok += 1
                last = t.replace("\n"," ")[:80]
            else:
                errs.append("empty")
        except Exception as e:
            errs.append(str(e)[:40])
    print("  max_side=%-5d bytes=%-7d ok=%d/3  %s  %s" % (max_side, len(small), ok, errs, last if ok else ""))
