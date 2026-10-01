import see, io, time
from PIL import Image, ImageDraw
buf=io.BytesIO()
im=Image.new("RGB",(400,200),(200,20,20)); d=ImageDraw.Draw(im)
d.rectangle([20,20,180,180],fill=(20,20,220)); d.text((200,90),"BLUE42",fill=(255,255,255))
im.save(buf,format="PNG"); b=buf.getvalue()
for m in ["qwen3.8-max","deepseek-v4-flash-vision-exp","minimax-m3","glm-5.3","kimi-k3","mimo-v2.6-pro"]:
    t0=time.time()
    try:
        r=see.ask_sighted(m,b,"Reply with ONLY the text you see and the colour of the left square.",attempts=1,timeout=100,max_tokens=50)
        print("%-32s OK %5.1fs -> %s" % (m, time.time()-t0, r.replace(chr(10)," ")[:50]))
    except Exception as e:
        print("%-32s -- %5.1fs  %s" % (m, time.time()-t0, str(e)[:60]))
