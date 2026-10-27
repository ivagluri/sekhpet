"""Write the models behind the look-up sheets and picker.html: every designer style of every body part
(on an otherwise default body) as a small GLB, and the colour palettes, into work/osrs-catalog/.
catalog.sh renders them."""
import json, shutil
from pathlib import Path
from cache import Cache
import anim, defs, export_glb, glb, names, player

OUT = names.ROOT / "work" / "osrs-catalog"


def main():
    cache = Cache(); kits = defs.load_all(cache, 3, defs.kit)
    lists = player.style_lists(kits)
    shutil.rmtree(OUT / "glb", ignore_errors=True); (OUT / "glb").mkdir(parents=True)
    count = 0
    for body in ("A", "B"):
        for part in player.PARTS:
            for n in range(1, len(lists[body][part]) + 1):
                o = player.Outfit(); o.body = body; o.styles[part] = n
                parts, recolours, _ = player.assemble(o, kits, {})
                _, verts, _, faces = export_glb.merged(cache, parts, recolours)
                pos, col, tris, _ = export_glb.mesh_arrays(verts, faces)
                glb.write(str(OUT / "glb" / f"{body}_{part}_{n:03d}.glb"), f"{body}{part}{n}", pos, col,
                          [[(0, 1.0)]] * len(pos), tris, [("root", -1, anim.ident())], [])
                count += 1
    pals = player.palettes()
    swatches = {name: [glb.hsl_to_rgb(c) for c in row] for name, row in zip(player.COLOURS, pals["pal"])}
    (OUT / "palettes.json").write_text(json.dumps(swatches))
    print(f"CATALOG_MODELS {count} styles -> {OUT / 'glb'}")


def page():
    """work/osrs-catalog/picker.html: the template with the catalog's styles, colours and (once rendered) items."""
    kits = defs.load_all(Cache(), 3, defs.kit)
    lists = player.style_lists(kits)
    data = {"styles": {body: {part: len(ids) for part, ids in parts.items()} for body, parts in lists.items()},
            "colours": json.loads((OUT / "palettes.json").read_text()),
            "items": json.loads((OUT / "items.json").read_text()) if (OUT / "items.json").exists() else None}
    text = (Path(__file__).parent / "picker.html").read_text().replace("/*CATALOG_DATA*/null", json.dumps(data))
    (OUT / "picker.html").write_text(text)
    print(f"PICKER {OUT / 'picker.html'}")


if __name__ == "__main__":
    import sys
    page() if "--page" in sys.argv else main()
