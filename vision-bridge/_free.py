import see, io, time
from PIL import Image, ImageDraw
buf=io.BytesIO()
im=Image.new("RGB",(400,200),(200,20,20)); d=ImageDraw.Draw(im)
d.rectangle([20,20,180,180],fill=(20,20,220)); d.text((200,90),"BLUE42",fill=(255,255,255))
im.save(buf,format="PNG"); b=buf.getvalue()
FREE=["space-bunny-free","longcat-2.5-preview-free"]
for m in FREE:
    for attempt in range(3):
        t0=time.time()
        try:
            r=see.ask_sighted(m,b,"Reply with ONLY the text you see and the colour of the left square. If you cannot see images reply NOVISION.",attempts=1,timeout=90,max_tokens=60)
            print("%-32s try%d OK %5.1fs -> %s" % (m,attempt+1,time.time()-t0,r.replace(chr(10)," ")[:60]))
            break
        except Exception as e:
            print("%-32s try%d -- %5.1fs %s" % (m,attempt+1,time.time()-t0,str(e)[:55]))
