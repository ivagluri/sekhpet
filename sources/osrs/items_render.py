"""Blender: an icon for every wearable item, as it looks dropped on the ground (its inventory model, lying as
the game draws it, seen from the game's overhead camera), plus work/osrs-catalog/items.json for picker.html.
Versions of an item that look the same share one icon. Run by catalog.sh --items:
  Blender --background --python items_render.py -- <catalog dir>"""
import bpy, json, math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cache import Cache
import defs, export_glb, glb, model as mdl

DIR = sys.argv[sys.argv.index("--") + 1]
OUT = os.path.join(DIR, "items"); os.makedirs(OUT, exist_ok=True)
SLOTS = {0: "head", 1: "cape", 2: "amulet", 3: "weapon", 4: "body", 5: "shield", 7: "legs", 9: "hands", 10: "feet"}
PITCH = math.radians(52)  # the camera looks down this far below level, as the game's does
SIZE = 128

cache = Cache(); items = defs.load_all(cache, 10, defs.item)
wearable = [i for i in items.values() if i["name"] and "male0" in i and "inv" in i and i.get("wearPos1") in SLOTS
            and "o98" not in i and "o149" not in i and "o140" not in i]
if os.environ.get("OSRS_ITEM_IDS"):  # a few items only, for trying the look out
    keep = {int(x) for x in os.environ["OSRS_ITEM_IDS"].split(",")}
    wearable = [i for i in wearable if i["id"] in keep]

bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"; sc.render.film_transparent = True
sc.display.shading.light = "STUDIO"; sc.display.shading.color_type = "VERTEX"
sc.display.shading.show_shadows = True; sc.display.shading.studio_light = "paint.sl"  # bright, like the game's
sc.view_settings.view_transform = "Standard"  # the default (AgX) mutes the game's colours
sc.render.resolution_x = sc.render.resolution_y = SIZE
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam); sc.camera = cam
cam.data.type = "ORTHO"; cam.rotation_euler = (math.pi / 2 - PITCH, 0, 0)
forward = (0, math.cos(PITCH), -math.sin(PITCH))  # the way the camera looks (from the south, downwards)


def icon(it, path):
    m = mdl.load(cache, it["inv"]); colour = dict(it["recolor"])
    verts = [(m.vx[i] / 128, m.vz[i] / 128, -m.vy[i] / 128) for i in range(m.nv)]  # Blender: z up
    faces, cols = [], []
    for f in range(m.nf):
        if (m.rtypes[f] & 3) == 2 or m.alphas[f] == 255: continue
        faces.append((m.f1[f], m.f2[f], m.f3[f]))
        rgb = glb.hsl_to_rgb(colour.get(m.colors[f], m.colors[f])) if m.tex[f] < 0 else (0.55, 0.55, 0.55)
        cols.append(tuple(c ** 2.2 for c in rgb) + (1.0,))
    if not faces: return False
    me = bpy.data.meshes.new("item"); me.from_pydata(verts, [], faces); me.update()
    attr = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    for poly, c in zip(me.polygons, cols):
        for li in poly.loop_indices: attr.data[li].color = c
    ob = bpy.data.objects.new("item", me); sc.collection.objects.link(ob)
    # frame it: the bounds as the camera sees them
    right, up = (1, 0, 0), (0, math.sin(PITCH), math.cos(PITCH))
    px = [sum(a * b for a, b in zip(v, right)) for v in verts]; py = [sum(a * b for a, b in zip(v, up)) for v in verts]
    cx, cy = (min(px) + max(px)) / 2, (min(py) + max(py)) / 2
    cam.data.ortho_scale = max(max(px) - min(px), max(py) - min(py)) * 1.12 or 0.1
    cam.location = [cx * r + cy * u - 10 * f for r, u, f in zip(right, up, forward)]
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(ob, do_unlink=True); bpy.data.meshes.remove(me)
    return True


# One entry per name and look; the first look of a name is plain, the others carry their item id
looks, entries = {}, {s: [] for s in SLOTS.values()}
for it in sorted(wearable, key=lambda i: i["id"]):
    key = (it["inv"], it["male0"], tuple(it["recolor"]), tuple(it["retexture"]))
    slot = SLOTS[it["wearPos1"]]
    same_name = [e for e in entries[slot] if e["name"] == it["name"]]
    if any(e["key"] == key for e in same_name): continue
    if key not in looks:
        f = f"{it['id']}.png"
        looks[key] = f if (os.path.exists(os.path.join(OUT, f)) or icon(it, os.path.join(OUT, f))) else None
    entries[slot].append({"name": it["name"], "id": it["id"], "key": key, "icon": looks[key],
                          "line": it["name"] + (f" #{it['id']}" if same_name else "")})
for slot in entries:
    entries[slot] = sorted(({k: e[k] for k in ("name", "id", "icon", "line")} for e in entries[slot]),
                           key=lambda e: (e["name"].lower(), e["id"]))
with open(os.path.join(DIR, "items.json"), "w") as f:
    json.dump(entries, f)
print("ITEMS_OK", sum(len(v) for v in entries.values()), "entries,", sum(1 for v in looks.values() if v), "icons")
