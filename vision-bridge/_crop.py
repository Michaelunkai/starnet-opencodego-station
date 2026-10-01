import see, io, glob, os
from PIL import Image
src = sorted(glob.glob("shots\\cap-*.png"))[-1]
raw = open(src,"rb").read()
im = Image.open(io.BytesIO(raw)).convert("RGB")
W,H = im.size
print("dashboard:", W, "x", H)
regions = {
  "left-crew-rail": (0, 0, int(W*0.30), int(H*0.80)),
  "comms-panel":    (int(W*0.55), int(H*0.25), W, H),
  "top-bar":        (0, 0, W, int(H*0.16)),
}
for name,(l,t,r,b) in regions.items():
    crop = im.crop((l,t,r,b))
    buf=io.BytesIO(); crop.save(buf, format="JPEG", quality=80)
    data = buf.getvalue()
    ok=0; last=""
    for i in range(2):
        try:
            txt = see.chat_vision("space-bunny-free", data,
                "Describe exactly what is visible in this image in one or two sentences, quoting any text you can read.",
                timeout=90, max_tokens=120)
            if txt.strip(): ok+=1; last=txt.replace("\n"," ")[:110]
        except Exception as e:
            last="ERR "+str(e)[:40]
    print("  %-16s %-11s %6d bytes  ok=%d/2  %s" % (name, "%dx%d"%(crop.size[0],crop.size[1]), len(data), ok, last))
