"""Player characters: an outfit.txt (body type, styles, colours, worn items) -> the models to merge.

Styles are numbered as the game's character designer lists them: a body type's selectable kits for that part,
in id order. Colours are indices into the client's five palettes (hair, torso, legs, feet, skin), which the
cache doesn't hold: they're read once from RuneLite's copy of the game client and kept in .tools/osrs."""
import glob, json, os, struct, zipfile
from pathlib import Path
from names import SHARED, TOOLS

PARTS = ["hair", "jaw", "torso", "arms", "hands", "legs", "feet"]  # kit body parts 0-6 (body type B: 7-13)
PART_SLOT = {0: 8, 1: 11, 2: 4, 3: 6, 4: 9, 5: 7, 6: 10}            # the equipment slot each part fills
COLOURS = ["hair", "torso", "legs", "feet", "skin"]
FIND = [6798, 8741, 25238, 4626, 4550]  # the colour each palette replaces on the body kits


# ---------- palettes ----------
def _clinit_arrays(data):
    """Run a class's static initialiser far enough to build its constant arrays: {field: array}."""
    p = 10; pool = [None]
    n = struct.unpack_from(">H", data, 8)[0]
    i = 1
    while i < n:
        tag = data[p]; p += 1
        if tag == 1:
            ln = struct.unpack_from(">H", data, p)[0]; pool.append(data[p + 2:p + 2 + ln].decode("utf-8", "replace")); p += 2 + ln
        elif tag == 3:
            pool.append(struct.unpack_from(">i", data, p)[0]); p += 4
        elif tag in (5, 6):
            pool += [None, None]; p += 8; i += 2; continue
        else:
            size = {4: 4, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4, 12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}[tag]
            pool.append(data[p:p + size]); p += size
        i += 1
    p += 6
    p += 2 * struct.unpack_from(">H", data, p)[0] + 2
    for _ in range(2):  # fields, then methods
        count = struct.unpack_from(">H", data, p)[0]; p += 2
        for _ in range(count):
            name = pool[struct.unpack_from(">H", data, p + 2)[0]]; p += 6
            attrs = struct.unpack_from(">H", data, p)[0]; p += 2
            for _ in range(attrs):
                aname = pool[struct.unpack_from(">H", data, p)[0]]; alen = struct.unpack_from(">I", data, p + 2)[0]
                if name == "<clinit>" and aname == "Code":
                    clen = struct.unpack_from(">I", data, p + 10)[0]
                    return _run(data[p + 14:p + 14 + clen], pool)
                p += 6 + alen
    return {}


def _run(code, pool):
    st = []; out = {}; pc = 0
    def field(idx):  # Fieldref -> NameAndType -> name
        nat = pool[struct.unpack_from(">H", pool[idx], 2)[0]]
        return pool[struct.unpack_from(">H", nat, 0)[0]]
    while pc < len(code):
        op = code[pc]
        if 0x02 <= op <= 0x08: st.append(op - 3); pc += 1
        elif op == 0x10: st.append(struct.unpack_from(">b", code, pc + 1)[0]); pc += 2
        elif op == 0x11: st.append(struct.unpack_from(">h", code, pc + 1)[0]); pc += 3
        elif op == 0x12: st.append(pool[code[pc + 1]]); pc += 2
        elif op == 0x13: st.append(pool[struct.unpack_from(">H", code, pc + 1)[0]]); pc += 3
        elif op == 0xBC: st.append([None] * st.pop()); pc += 2
        elif op == 0xBD: st.append([None] * st.pop()); pc += 3
        elif op == 0x59: st.append(st[-1]); pc += 1
        elif op in (0x4F, 0x53, 0x56): v = st.pop(); k = st.pop(); st.pop()[k] = v; pc += 1
        elif op == 0xB3: out[field(struct.unpack_from(">H", code, pc + 1)[0])] = st.pop(); pc += 3
        elif op == 0xA7: pc += struct.unpack_from(">h", code, pc + 1)[0]
        elif op == 0xB1: break
        else: break  # anything else: the arrays are already built
    return out


def palettes():
    """{'pal': [5 lists], 'find2': [5], 'pal2': [5 lists]}, from the client's colour tables."""
    jars = sorted(glob.glob(os.path.expanduser("~/.runelite/repository2/injected-client-*.jar")), key=os.path.getmtime)
    cached = TOOLS / "palettes.json"
    if cached.exists():
        data = json.loads(cached.read_text())
        if not jars or data.get("jar") == os.path.basename(jars[-1]):
            return data
    if not jars:
        raise SystemExit("No RuneLite injected-client jar in ~/.runelite/repository2 (run RuneLite once)")
    needles = [b"\x11" + struct.pack(">h", v) for v in FIND]
    with zipfile.ZipFile(jars[-1]) as z:
        for name in z.namelist():
            if not name.endswith(".class"): continue
            data = z.read(name)
            if not all(nd in data for nd in needles): continue
            arrays = _clinit_arrays(data)
            ones = [v for v in arrays.values() if isinstance(v, list) and len(v) == 5 and all(isinstance(x, int) for x in v)]
            twos = [v for v in arrays.values() if isinstance(v, list) and len(v) == 5 and all(isinstance(x, list) for x in v)]
            pal = next((t for t in twos if all(t[i] and t[i][0] == FIND[i] for i in range(5))), None)
            find2 = next((o for o in ones if o != FIND), None)
            pal2 = next((t for t in twos if t is not pal), None)
            if pal and find2 and pal2:
                u = lambda v: v & 0xFFFF
                res = {"jar": os.path.basename(jars[-1]), "class": name,
                       "pal": [[u(x) for x in row] for row in pal],
                       "find2": [u(x) if x != -1 else -1 for x in find2],
                       "pal2": [[u(x) for x in row] for row in pal2]}
                TOOLS.mkdir(parents=True, exist_ok=True); cached.write_text(json.dumps(res))
                return res
    raise SystemExit("Couldn't find the player colour tables in the RuneLite client jar")


def colour_recolours(colours, pals):
    """Designer colour indices (1-based, 0 = default) -> [(find, replace)] for the whole model."""
    out = []
    for i, idx in enumerate(colours):
        k = max(0, idx - 1)
        if k < len(pals["pal"][i]): out.append((FIND[i], pals["pal"][i][k]))
        if pals["find2"][i] != -1 and k < len(pals["pal2"][i]): out.append((pals["find2"][i], pals["pal2"][i][k]))
    return out


# ---------- outfit ----------
class Outfit:
    def __init__(self):
        self.body = "A"; self.styles = {}; self.colours = [0] * 5
        self.items = []; self.stance = "auto"; self.combat = "auto"; self.emotes = "default"


def read_outfit(path, outfit=None, seen=()):
    """Parse an outfit file (see sources/osrs/README.md); include: lines pull in other files first."""
    o = outfit or Outfit(); path = Path(path)
    if path in seen: return o
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip() if not raw.lstrip().startswith("#") else ""
        hashid = raw.split("#", 1)[1].strip() if "#" in raw and raw.split("#", 1)[1].strip().isdigit() else None
        if not line: continue
        key, _, val = line.partition(":")
        key = key.strip().lower().replace("color", "colour"); val = val.strip()
        if _ and key == "include":
            inc = Path(val) if val.endswith(".txt") else SHARED / "outfits" / f"{val}.txt"
            if not inc.is_absolute() and not inc.exists(): inc = path.parent / inc
            read_outfit(inc, o, seen + (path,))
        elif _ and key == "body": o.body = val.upper()[:1]
        elif _ and key in PARTS: o.styles[key] = int(val)
        elif _ and key.endswith(" colour") and key[:-7] in COLOURS: o.colours[COLOURS.index(key[:-7])] = int(val)
        elif _ and key == "stance": o.stance = val
        elif _ and key == "combat": o.combat = val
        elif _ and key == "emotes": o.emotes = val
        else: o.items.append((line, int(hashid) if hashid else None))
    return o


def find_item(items, name, iid=None):
    if iid is not None:
        if iid not in items: raise SystemExit(f"No item with id {iid}")
        return items[iid]
    cands = [i for i in items.values() if (i["name"] or "").lower() == name.lower() and "male0" in i
             and "o98" not in i and "o149" not in i and "o140" not in i]  # not noted, placeholder or bought
    if not cands:
        import difflib
        names = {i["name"].lower(): i["name"] for i in items.values() if i["name"] and "male0" in i}
        close = [names[n] for n in difflib.get_close_matches(name.lower(), list(names), n=6, cutoff=0.6)]
        raise SystemExit(f"No wearable item called {name!r} (check the spelling, or add #<item id>)"
                         + (f". Close: {', '.join(close)}" if close else ""))
    if len({i["male0"] for i in cands}) > 1:
        print(f"NOTE {name!r}: several versions {[i['id'] for i in cands]}, using {cands[0]['id']} (add #<id> to choose)")
    return min(cands, key=lambda i: i["id"])


def style_lists(kits):
    """{body type: {part name: [kit ids in designer order]}}."""
    out = {"A": {}, "B": {}}
    for body, base in (("A", 0), ("B", 7)):
        for k, part in enumerate(PARTS):
            out[body][part] = [x["id"] for x in sorted(kits.values(), key=lambda x: x["id"]) if x["part"] == base + k and x["selectable"]]
    return out


def assemble(outfit, kits, items):
    """-> ([(model id, recolours, y offset)], whole-model recolours, worn items)."""
    lists = style_lists(kits)[outfit.body]
    worn = []
    for name, iid in outfit.items:  # a later item in the same slot replaces an earlier one (an include's)
        it = find_item(items, name, iid)
        for old in [w for w in worn if w.get("wearPos1") == it.get("wearPos1")]:
            print(f"NOTE {it['name']} replaces {old['name']} (same slot)"); worn.remove(old)
        worn.append(it)
    covered = set()
    for it in worn:
        for k in ("wearPos1", "wearPos2", "wearPos3"):
            if it.get(k, -1) >= 0: covered.add(it[k])
    parts = []
    for k, part in enumerate(PARTS):
        if PART_SLOT[k] in covered: continue
        options = lists[part]
        if not options: continue
        n = outfit.styles.get(part, 1)
        if not 1 <= n <= len(options):
            raise SystemExit(f"{part}: style {n} doesn't exist (1-{len(options)} for body type {outfit.body})")
        kit = kits[options[n - 1]]
        parts += [(m, kit["recolor"], 0) for m in kit["models"]]
    sex = "male" if outfit.body == "A" else "female"
    for it in worn:
        for key in (f"{sex}0", f"{sex}1", f"{sex}2"):
            if it.get(key, -1) >= 0:
                parts.append((it[key], it["recolor"], it.get(f"{sex}Offset", 0) if key.endswith("0") else 0))
    return parts, colour_recolours(outfit.colours, palettes()), worn


TEMPLATE = """# A player character: one entry per line; text after # is ignored. See sources/osrs/README.md.
# Style and colour numbers are the character designer's (1 = first); bash sources/osrs/catalog.sh
# draws numbered sheets of them in work/osrs-catalog/.
# include: dragon            # lines from characters/_osrs/outfits/dragon.txt, a reusable loadout
body: A                      # A or B
hair: 1                      # also jaw, torso, arms, hands, legs, feet
hair colour: 1               # also torso colour, legs colour, feet colour, skin colour
# Items to wear, by in-game name (add #<item id> to pick one version):
# Abyssal whip
stance: auto                 # or an animation name or id for the weapon stance's idle
combat: auto                 # or animation names/ids, comma separated; "none" for no attacks
emotes: default              # characters/_osrs/emotes.txt, or a file in this folder
"""
