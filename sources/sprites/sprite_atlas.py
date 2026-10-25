"""Pack a sprite character's frames into one texture, for sources/sprites/sprite_build.py.

  python3 sources/sprites/sprite_atlas.py characters/<name>/character.json work/<name>/sprites

Writes atlas.png (every distinct frame, scaled up by whole pixels so it stays sharp when
the app's filtering magnifies it) and layout.json: each pose's frames, with each frame's
front, side and back sprite (its place in the atlas and its size in sprite pixels) and
how long the frame shows.
"""
import json
import sys
from pathlib import Path

from PIL import Image

SPEC_PATH = Path(sys.argv[1]).resolve()
SPEC = json.loads(SPEC_PATH.read_text())
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
IMAGES = (SPEC_PATH.parent / SPEC['images']).expanduser().resolve()  # relative to the character folder
PREFIX = SPEC.get('prefix', '')
LIMIT = 1024  # the exporter scales bigger textures down (smoothly), so stay within it


def frames(name):
    """[(RGBA image, seconds)] of an image file named <prefix><name> or <name>: a GIF, PNG or
    WebP, animated or not."""
    path = next((IMAGES / f'{stem}{ext}' for stem in (PREFIX + name, name) for ext in ('.gif', '.png', '.webp')
                 if (IMAGES / f'{stem}{ext}').exists()), None)
    if path is None:
        sys.exit(f'No image for {name!r} in {IMAGES} (tried {PREFIX + name!r} and {name!r} as .gif/.png/.webp)')
    gif = Image.open(path)
    out = []
    for index in range(getattr(gif, 'n_frames', 1)):
        gif.seek(index)
        out.append((gif.convert('RGBA'), (gif.info.get('duration') or 0) / 1000))
    # Empty margins trimmed (frames are lined up by their bottom centre, so a padded canvas
    # would float), by the union over the frames so the animation keeps its own movement.
    boxes = [image.getchannel('A').getbbox() for image, _ in out]
    boxes = [b for b in boxes if b]
    if boxes:
        box = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
        out = [(image.crop(box), seconds) for image, seconds in out]
    return out


def side(name):
    """A side view's frames, facing left: those drawn facing right are mirrored."""
    out = frames(name)
    if SPEC.get('sideFacesRight'):
        out = [(image.transpose(Image.FLIP_LEFT_RIGHT), seconds) for image, seconds in out]
    return out


images, keys = [], {}


def sprite(image):
    """Index of a distinct image, by its pixels."""
    key = (image.size, image.tobytes())
    if key not in keys:
        keys[key] = len(images)
        images.append(image)
    return keys[key]


poses = {}
for pose, views in SPEC['poses'].items():
    front = frames(views['front'])
    # Without a side or back view the front one stands in, so the pet never turns edge-on.
    side_view = side(views['side']) if 'side' in views else side(SPEC['defaultSide']) if 'defaultSide' in SPEC else front
    back = frames(views['back']) if 'back' in views else frames(SPEC['defaultBack']) if 'defaultBack' in SPEC else front
    poses[pose] = [{'front': sprite(image), 'side': sprite(side_view[i % len(side_view)][0]),
                    'back': sprite(back[i % len(back)][0]), 'seconds': seconds}
                   for i, (image, seconds) in enumerate(front)]

# Rows of sprites at their own sizes, with a gap so neighbours never bleed into each other;
# the biggest whole-pixel scale that fits.
def shelves(scale):
    places, x, y, row = [], 0, 0, 0
    for image in images:
        w, h = (image.width + 2) * scale, (image.height + 2) * scale
        if x + w > LIMIT:
            x, y, row = 0, y + row, 0
        places.append((x + scale, y + scale))
        x, row = x + w, max(row, h)
    return places, y + row


scale = 1
while shelves(scale + 1)[1] <= LIMIT:
    scale += 1
places, height = shelves(scale)
atlas = Image.new('RGBA', (LIMIT, height))
rects = []
for image, (x, y) in zip(images, places):
    atlas.paste(image.resize((image.width * scale, image.height * scale), Image.NEAREST), (x, y))
    # UVs: 0..1, origin bottom-left.
    rects.append({'u0': x / atlas.width, 'u1': (x + image.width * scale) / atlas.width,
                  'v0': 1 - (y + image.height * scale) / atlas.height, 'v1': 1 - y / atlas.height,
                  'w': image.width, 'h': image.height})
atlas.save(OUT / 'atlas.png')
(OUT / 'layout.json').write_text(json.dumps({'sprites': rects, 'poses': poses}, indent=1))
print(f'ATLAS_OK {len(images)} sprites, x{scale}, {atlas.width}x{atlas.height}')
