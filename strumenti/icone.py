# Ricolora lo sfondo bianco del logo (solo lo sfondo: cappello e grembiule panna restano) e crea le icone.
# Uso (dalla cartella vico-agenti): python3 strumenti/icone.py   — i colori sono in COLORI qui sotto.
import sys
from PIL import Image, ImageDraw, ImageFilter

SRC = "assets/img/logo.jpg"
COLORI = {"titolare": (134, 182, 74),   # verde basilico dell'app (#86b64a)
          "agente":   (135, 206, 235)}  # celeste (#87ceeb)
TESTO_DA_Y = 590   # sotto la mascotte c'è solo la scritta: lì è sfondo anche il bianco dentro le lettere

base = Image.open(SRC).convert("RGB")
W, H = base.size
px = base.load()

# 1) pixel bianchi "neutri" (lo sfondo è 253,253,253; il panna ha il blu molto più basso)
neutro = Image.new("L", (W, H), 0)
n = neutro.load()
for y in range(H):
    for x in range(W):
        r, g, b = px[x, y]
        if min(r, g, b) >= 238 and max(r, g, b) - min(r, g, b) <= 10:
            n[x, y] = 255

# 2) sfondo = bianco collegato ai bordi + bianco dentro le lettere della scritta
riemp = neutro.copy()
for seme in [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1), (W // 2, 0), (W // 2, H - 1), (0, H // 2), (W - 1, H // 2)]:
    if riemp.getpixel(seme) == 255:
        ImageDraw.floodfill(riemp, seme, 128)
sfondo = Image.new("L", (W, H), 0)
s = sfondo.load()
r_ = riemp.load()
for y in range(H):
    for x in range(W):
        if r_[x, y] == 128 or (y >= TESTO_DA_Y and n[x, y] == 255):
            s[x, y] = 255

# 3) bordo sfumato: 2 pixel attorno allo sfondo, dove il disegno si mescola col bianco
bordo = sfondo.filter(ImageFilter.MaxFilter(5))
b_ = bordo.load()

def ricolora(colore):
    out = base.copy()
    o = out.load()
    for y in range(H):
        for x in range(W):
            if s[x, y]:
                o[x, y] = colore
            elif b_[x, y]:
                p = px[x, y]
                t = min(p) / 255.0          # quanto "bianco" c'è in questo pixel
                o[x, y] = tuple(max(0, min(255, round(p[i] + t * (colore[i] - 255)))) for i in range(3))
    return out

for nome, colore in COLORI.items():
    img = ricolora(colore)
    img.resize((512, 512), Image.LANCZOS).save(f"assets/img/icona-{nome}-512.png", optimize=True)
    img.resize((192, 192), Image.LANCZOS).save(f"assets/img/icona-{nome}-192.png", optimize=True)
    img.resize((180, 180), Image.LANCZOS).save(f"assets/img/icona-{nome}-180.png", optimize=True)
    # "maskable" per Android: logo un po' più piccolo, così non viene tagliato dal cerchio
    tela = Image.new("RGB", (512, 512), colore)
    tela.paste(img.resize((400, 400), Image.LANCZOS), (56, 56))
    tela.save(f"assets/img/icona-{nome}-maskable.png", optimize=True)
    print(nome, "ok")
