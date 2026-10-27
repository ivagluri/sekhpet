"""Lists a character's face colours, to pick `glow` (or recolours) from: each colour's id, how it looks,
how many faces use it, and where they sit (left/right, height, front/back, in metres).

  python3 sources/osrs/colours.py characters/<name>"""
import json, sys
from collections import defaultdict
from pathlib import Path
from cache import Cache
import export_glb, glb


def main(folder):
    folder = Path(folder)
    spec = json.loads((folder / "character.json").read_text())
    cache = Cache()
    parts, recolours, _, _ = export_glb.parts_of(cache, folder, spec)
    _, verts, _, faces = export_glb.merged(cache, parts, recolours, hide=set(spec["osrs"].get("hideFaceGroups", [])))
    where = defaultdict(list)
    for a, b, c, hsl in faces:
        if hsl is not None:
            where[hsl].append([sum(export_glb.to_gl(verts[v])[k] for v in (a, b, c)) / 3 for k in range(3)])
    glow = set(spec["osrs"].get("glow", []))
    for hsl, centres in sorted(where.items(), key=lambda kv: len(kv[1])):
        rgb = "#" + "".join(f"{round(v * 255):02x}" for v in glb.hsl_to_rgb(hsl))
        lo = [min(c[k] for c in centres) for k in range(3)]; hi = [max(c[k] for c in centres) for k in range(3)]
        span = "  ".join(f"{axis} {l:+.2f}..{h:+.2f}" for axis, l, h in zip("xyz", lo, hi))
        print(f"{hsl:6d}  {rgb}  {len(centres):4d} faces  {span}{'  (glow)' if hsl in glow else ''}")


if __name__ == "__main__":
    main(sys.argv[1])
