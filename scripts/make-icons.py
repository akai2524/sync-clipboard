"""Build original code-drawn icons; no remote images or external branding."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
out = root / 'assets'
out.mkdir(exist_ok=True)
s = 4
im = Image.new('RGBA', (256*s, 256*s))
d = ImageDraw.Draw(im)
def box(xy, r, fill, outline=None, width=1):
    d.rounded_rectangle(tuple(round(v*s) for v in xy), r*s, fill, outline, width*s)
def line(points, fill, width):
    d.line([(round(x*s),round(y*s)) for x,y in points], fill=fill, width=width*s, joint='curve')
box((8,8,248,248),57,'#126FE3')
box((99,47,199,177),18,'#84C4FF')
box((57,79,161,209),18,'#FFFFFF')
box((85,66,133,89),9,'#FFFFFF')
line([(81,119),(127,119),(119,110)],'#126FE3',9)
line([(127,119),(119,128)],'#126FE3',9)
line([(137,164),(91,164),(99,155)],'#126FE3',9)
line([(91,164),(99,173)],'#126FE3',9)
im=im.resize((256,256),Image.Resampling.LANCZOS)
im.save(out/'lightclip.png')
im.save(out/'lightclip.ico',sizes=[(16,16),(20,20),(24,24),(32,32),(40,40),(48,48),(64,64),(128,128),(256,256)])
(out/'lightclip.svg').write_text('''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect x="8" y="8" width="240" height="240" rx="57" fill="#126fe3"/><rect x="99" y="47" width="100" height="130" rx="18" fill="#84c4ff"/><rect x="57" y="79" width="104" height="130" rx="18" fill="white"/><rect x="85" y="66" width="48" height="23" rx="9" fill="white"/><path d="M81 119h46l-8-9m8 9-8 9M137 164H91l8-9m-8 9 8 9" fill="none" stroke="#126fe3" stroke-width="9" stroke-linejoin="round" stroke-linecap="round"/></svg>''',encoding='utf-8')
print(out/'lightclip.ico')
