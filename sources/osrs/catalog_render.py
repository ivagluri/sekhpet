"""Blender: render work/osrs-catalog/glb/*.glb into numbered sheets, one per body type and part, plus the
colour palettes. Run by catalog.sh:  Blender --background --python catalog_render.py -- <catalog dir>"""
import bpy, glob, json, math, os, sys
from collections import defaultdict

DIR = sys.argv[sys.argv.index("--") + 1]
# The part of the body each sheet frames (metres up from the floor)
REGION = {"hair": (1.12, 1.72), "jaw": (1.15, 1.6), "torso": (0.75, 1.4), "arms": (0.72, 1.4),
          "hands": (0.62, 0.98), "legs": (0.0, 0.95), "feet": (0.0, 0.3)}
COLS = 10


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"; sc.display.shading.color_type = "VERTEX"
    sc.world = bpy.data.worlds.new("w"); sc.world.color = (0.16, 0.17, 0.2)
    sc.view_settings.view_transform = "Standard"  # the default (AgX) mutes the game's colours
    return sc


def label(text, x, z, size):
    curve = bpy.data.curves.new(text, "FONT"); curve.body = text; curve.size = size; curve.align_x = "CENTER"
    ob = bpy.data.objects.new(text, curve); ob.location = (x, -0.5, z); ob.rotation_euler = (math.pi / 2, 0, 0)
    mat = bpy.data.materials.new("white"); mat.diffuse_color = (1, 1, 1, 1); curve.materials.append(mat)
    bpy.context.scene.collection.objects.link(ob)


def camera(sc, width, height, cx, cz):
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam)
    cam.data.type = "ORTHO"; cam.data.ortho_scale = max(width, height)
    cam.location = (cx, -10, cz); cam.rotation_euler = (math.pi / 2, 0, 0); sc.camera = cam
    sc.render.resolution_x = 1600; sc.render.resolution_y = max(200, int(1600 * height / width))


def clip(ob, lo, hi):
    """Drop the faces outside the sheet's body region so neighbouring rows don't overlap."""
    import bmesh
    bm = bmesh.new(); bm.from_mesh(ob.data)
    z = lambda v: (ob.matrix_world @ v.co).z
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if not all(lo <= z(v) <= hi for v in f.verts)], context="FACES")
    bm.to_mesh(ob.data); bm.free()


def sheet(body, part, files):
    """Each style's body region [lo, hi] sits in a grid cell, its number just below it."""
    sc = reset(); lo, hi = REGION[part]; span = hi - lo
    cell = span * 1.3; step = span * 0.9
    for k, f in enumerate(files):
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=f)
        x, row = (k % COLS) * step, k // COLS
        for ob in set(bpy.data.objects) - before:
            if ob.type == "MESH": clip(ob, lo - 0.02, hi + 0.02)
            if ob.parent is None: ob.location = (x, 0, -row * cell - lo)
        label(str(k + 1), x, -row * cell - span * 0.15, span * 0.1)
    rows = (len(files) + COLS - 1) // COLS
    top, bottom = span * 1.05, -(rows - 1) * cell - span * 0.25
    camera(sc, COLS * step, top - bottom, (COLS - 1) * step / 2, (top + bottom) / 2)
    sc.render.filepath = os.path.join(DIR, f"body-{body}-{part}.png")
    bpy.ops.render.render(write_still=True)


def swatches():
    sc = reset(); sc.display.shading.light = "FLAT"; sc.display.shading.color_type = "MATERIAL"
    pals = json.load(open(os.path.join(DIR, "palettes.json")))
    for r, (name, row) in enumerate(pals.items()):
        label(name, -1.6, -r * 1.3 - 0.15, 0.4)
        for k, rgb in enumerate(row):
            bpy.ops.mesh.primitive_plane_add(size=0.9, location=(k, 0, -r * 1.3), rotation=(math.pi / 2, 0, 0))
            mat = bpy.data.materials.new(f"{name}{k}"); mat.diffuse_color = (*(c ** 2.2 for c in rgb), 1)
            bpy.context.active_object.data.materials.append(mat)
            label(str(k + 1), k, -r * 1.3 - 0.75, 0.3)
    width, height = 33, len(pals) * 1.3 + 0.6
    camera(sc, width, height, 13.5, -(len(pals) - 1) * 1.3 / 2 - 0.2)
    sc.render.filepath = os.path.join(DIR, "colours.png")
    bpy.ops.render.render(write_still=True)


def thumbs(body, part, files):
    """One transparent picture per style, framing its body region, for picker.html (thumbs/A-hair-6.png).
    Style 1 of the hair also gives the body type's full-length picture (thumbs/A-body.png)."""
    sc = reset(); sc.render.film_transparent = True
    out = os.path.join(DIR, "thumbs"); os.makedirs(out, exist_ok=True)
    lo, hi = REGION[part]; span = hi - lo
    camera(sc, span * 1.15, span * 1.15, 0, (lo + hi) / 2)
    sc.render.resolution_x = sc.render.resolution_y = 330
    for k, f in enumerate(files):
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=f)
        added = set(bpy.data.objects) - before
        if part == "hair" and k == 0:
            sc.camera.data.ortho_scale = 1.95; sc.camera.location.z = 0.92
            sc.render.resolution_x, sc.render.resolution_y = 270, 540
            sc.render.filepath = os.path.join(out, f"{body}-body.png")
            bpy.ops.render.render(write_still=True)
            sc.camera.data.ortho_scale = span * 1.15; sc.camera.location.z = (lo + hi) / 2
            sc.render.resolution_x = sc.render.resolution_y = 330
        for ob in added:
            if ob.type == "MESH": clip(ob, lo - 0.02, hi + 0.02)
        sc.render.filepath = os.path.join(out, f"{body}-{part}-{k + 1}.png")
        bpy.ops.render.render(write_still=True)
        for ob in added: bpy.data.objects.remove(ob, do_unlink=True)


groups = defaultdict(list)
for f in sorted(glob.glob(os.path.join(DIR, "glb", "*.glb"))):
    body, part, _ = os.path.basename(f)[:-4].split("_")
    groups[(body, part)].append(f)
for (body, part), files in sorted(groups.items()):
    sheet(body, part, files)
    thumbs(body, part, files)
swatches()
print("CATALOG_OK", DIR)
