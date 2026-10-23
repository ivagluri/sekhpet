"""Build an app icon from a SekhPet `--icon` render (build_app.sh --icon-pet runs this).

  python3 scripts/make_icon.py <render.png> <AppIcon.icns>

Composites the transparent portrait onto a macOS-style rounded tile (824 px square
in a 1024 canvas), coloured from the pet itself, and packs every size with iconutil.
The icon is made from your own pack, so it stays out of the repository.
"""
import subprocess
import sys
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

render, output = Path(sys.argv[1]), Path(sys.argv[2])
SIZE, TILE, RADIUS = 1024, 824, 185
inset = (SIZE - TILE) // 2

portrait = Image.open(render).convert('RGBA').resize((TILE, TILE), Image.LANCZOS)
# The pet's average colour, from its visible pixels, sets the tile's tones.
opaque = [p[:3] for p in portrait.resize((64, 64)).getdata() if p[3] > 128] or [(90, 90, 120)]
average = [sum(c[i] for c in opaque) / len(opaque) for i in range(3)]


def tone(factor, lift=0):
    return tuple(round(min(255, c * factor + lift)) for c in average)


# Vertical gradient in darkened versions of the pet's colour.
top, bottom = tone(0.45, 18), tone(0.18, 6)
background = Image.new('RGBA', (TILE, TILE))
pixels = background.load()
for y in range(TILE):
    t = y / (TILE - 1)
    colour = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,)
    for x in range(TILE):
        pixels[x, y] = colour
# A soft, lighter glow behind the head.
glow = Image.new('L', (TILE, TILE), 0)
ImageDraw.Draw(glow).ellipse((TILE * 0.18, TILE * 0.08, TILE * 0.82, TILE * 0.72), fill=120)
glow = glow.filter(ImageFilter.GaussianBlur(90))
background = Image.composite(Image.new('RGBA', (TILE, TILE), tone(1.1, 60) + (255,)), background, glow)
background.alpha_composite(portrait)

mask = Image.new('L', (TILE, TILE), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, TILE - 1, TILE - 1), RADIUS, fill=255)
tile = Image.new('RGBA', (TILE, TILE), (0, 0, 0, 0))
tile.paste(background, (0, 0), mask)

icon = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
shadow = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 90), (inset, inset + 12), mask)
icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
icon.alpha_composite(tile, (inset, inset))

with tempfile.TemporaryDirectory() as tmp:
    iconset = Path(tmp) / 'AppIcon.iconset'
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f'icon_{points}x{points}' + ('@2x' if scale == 2 else '') + '.png'
            icon.resize((px, px), Image.LANCZOS).save(iconset / name)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(output)], check=True)
icon.save(output.with_suffix('.png'))
print(f'wrote {output}')
