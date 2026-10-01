import see, io, time
from PIL import Image, ImageDraw
buf=io.BytesIO()
im=Image.new("RGB",(400,200),(200,20,20)); d=ImageDraw.Draw(im)
d.rectangle([20,20,180,180],fill=(20,20,220)); d.text((200,90),"BLUE42",fill=(255,255,255))
im.save(buf,format="PNG"); img=buf.getvalue()
for m in ["space-bunny-free","longcat-2.5-preview-free"]:
    # TEXT only
    try:
        r=see.chat_vision(m,b"",  "Reply with the single word OK.", timeout=60, max_tokens=10)
        print("%-30s TEXT  OK -> %r" % (m, r[:20]))
    except Exception as e:
        print("%-30s TEXT  ERR %s" % (m, str(e)[:50]))
    # IMAGE
    try:
        r=see.chat_vision(m,img,"Describe the background colour in one short sentence.",timeout=90,max_tokens=60)
        print("%-30s IMAGE OK -> %r" % (m, r.replace(chr(10)," ")[:70]))
    except Exception as e:
        print("%-30s IMAGE ERR %s" % (m, str(e)[:50]))
