"""Draft a character folder for an OSRS NPC or player character: characters/<name>/character.json (the
rigged route's import spec, with an "osrs" block naming the sequences), clip-config.json (the pet's
behaviour) and clips.txt (the clips that could be added). Edit them and re-run; a draft is never overwritten
unless asked (--redraft).

  python3 sources/osrs/draft.py <name words> [--id N] [--player] [--redraft]"""
import argparse, json, os, re, sys
from cache import Cache
import anim, defs, maya, names, player

ROOT = names.ROOT
WALK_SPEED, RUN_SPEED = 1 / 0.6, 2 / 0.6   # a tile (taken as a metre) per 0.6 s game tick; running covers two
EXCLUDE = {"DEATH", "DIE", "DIES", "DEAD", "SPAWN", "DESPAWN", "CHATHEAD", "TURN", "TURNONSPOT", "ROTATE",
           "WALK", "RUN"}  # other walk/run cycles: the NPC's own walk and run are already the gaits
MAX_SECONDS = 20.0


def words_of(label):
    """CALLISTO_CUB_DEATH01 -> {CALLISTO, CUB, DEATH}: name words without their numbering."""
    return {re.sub(r"\d+$", "", w) for w in label.split("_")}


def slug(words):
    return re.sub(r"[^a-z0-9]", "", words.lower())


def camel(words):
    return "".join(w[:1].upper() + w[1:] for w in re.split(r"[^A-Za-z0-9]+", words) if w) or "Pet"


def seconds(seq):
    if seq["maya"] >= 0:  # skeletal: its length is in the curves; a sequence may name a range of it
        return (seq["mayaEnd"] - seq["mayaStart"]) * 0.02 if "mayaEnd" in seq else 1.0
    return sum(min(max(n, 1) * 0.02, 2.0) for n in seq["lengths"])


def skeleton_index(cache, seqs):
    """{sequence id: skeleton key} (a classic framemap id, or ("maya", skeleton id)), kept in .tools/osrs."""
    path = names.TOOLS / "seq-skeletons.json"
    stamp = os.path.getmtime(os.path.join(cache.path, "main_file_cache.dat2"))
    if path.exists():
        data = json.loads(path.read_text())
        if data.get("stamp") == stamp:
            return {int(k): (tuple(v) if isinstance(v, list) else v) for k, v in data["index"].items()}
    frames = anim.Frames(cache); index = {}
    for sid, s in seqs.items():
        try:
            if s["maya"] >= 0: index[sid] = ("maya", maya.skeleton_of(cache, s["maya"]))
            elif s["frames"]: index[sid] = frames.framemap_id(s["frames"][0])
        except Exception:
            pass
    names.TOOLS.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"stamp": stamp, "index": index}))
    return index


def pick_npc(npcs, words, nid):
    if nid is not None:
        return npcs[nid]
    found = [n for n in npcs.values() if (n["name"] or "").lower() == words.lower() and n["models"]
             and n.get("stand") not in (None, 65535)]
    if not found:
        close = sorted({n["name"] for n in npcs.values() if n["name"] and words.lower() in n["name"].lower()})[:15]
        raise SystemExit(f"No animated NPC called {words!r}." + (f" Close: {', '.join(close)}" if close else ""))
    distinct = {}
    for n in found:
        distinct.setdefault((tuple(n["models"]), tuple(n["recolor"]), n.get("stand"), n.get("walk")), n)
    choice = min(distinct.values(), key=lambda n: n["id"])
    if len(distinct) > 1:
        print(f"NOTE {len(distinct)} different {words!r} NPCs; using {choice['id']}. Others (re-run with --id):")
        for n in sorted(distinct.values(), key=lambda n: n["id"]):
            print(f"  --id {n['id']}: models {n['models'][:6]}{'…' if len(n['models']) > 6 else ''}")
    return choice


def emote_clips(folder, cache, nm, human, which="default"):
    shared = names.emote_file(names.SHARED / "emotes.txt", list(defs.enum(cache.files(2, 8)[names.EMOTE_ENUM]).values()), nm, human)
    own = folder / (which if which not in ("default", "") else "emotes.txt")
    return names.read_emotes(own if own.exists() else shared, nm, human)


def human_config(clips, emotes, attacks):
    """Behaviour for a human (player or human NPC): emotes as surprises, wave on click."""
    em = [c for c, _ in emotes]
    single = "Wave" if "Wave" in em else (em[0] if em else None)
    double = attacks[0] if attacks else next((c for c in ("JumpForJoy", "Cheer", "Dance") if c in em), em[1] if len(em) > 1 else (em[0] if em else "Idle"))
    held = next((c for c in ("Flap", "Panic") if c in em), None)
    cfg = {"groups": {}, "idleVariants": [], "submenus": {"Emotes": em} if em else {},
           "input": {"singleClick": [{"clip": single, "weight": 1}] if single else [], "doubleClick": double}}
    if held:
        cfg["groups"]["Held"] = {"start": [], "loop": held, "end": []}
        cfg["input"]["dragGroup"] = "Held"
    return cfg


def creature_config(clips, names_of):
    """Behaviour for a creature, from its clips' names: other idles drift in, lie/sleep/get up is a group,
    an attack is the double-click and a defend/block the click."""
    def has(c, *words): return any(w in words_of(names_of[c]) for w in words)
    rest = [c for c in clips if c not in ("Idle", "Walk", "Run")]
    variants = [c for c in rest if has(c, "READY", "IDLE")]
    groups = {}
    lie = next((c for c in rest if has(c, "LAY", "LIE", "LAYDOWN", "LIEDOWN")), None)
    sleep = next((c for c in rest if has(c, "SLEEP", "SLEEPING") and c != lie), None)
    up = next((c for c in rest if has(c, "GET", "GETUP", "WAKE", "STAND") and c not in (lie, sleep)), None)
    if lie and sleep and up:
        groups["Sleep"] = {"start": [lie], "loop": sleep, "end": [up]}
        variants = [v for v in variants if v not in (lie, sleep, up)]
    attack = next((c for c in rest if has(c, "ATTACK")), None)
    poke = next((c for c in rest if has(c, "DEFEND", "BLOCK", "DEFENCE")), None)
    others = [c for c in rest if c not in variants]
    return {"groups": groups, "idleVariants": variants,
            "input": {"singleClick": [{"clip": poke or next((o for o in others if o != attack), others[0] if others else "Idle"),
                                       "weight": 1}],
                      "doubleClick": attack or (others[-1] if others else "Idle")}}


def look_bone(cache, parts, recolours, scale, human):
    """The head's label bone, for watching the cursor: a human's highest label; for a creature, the biggest
    label in the front, upper part of the body (its highest are often a raised tail)."""
    import export_glb, model as mdl
    _, verts, labels, _ = export_glb.merged(cache, parts, recolours, scale)
    weights = [w for mid, _, _ in parts for w in (mdl.load(cache, mid).maya or [])]
    skeletal = len(weights) == len(verts)
    if skeletal:  # skeletal NPCs: group vertices by their strongest bone instead of a label
        labels = [max(w, key=lambda gw: gw[1])[0] if w else 0 for w in weights]
    groups = {}
    for v, l in zip(verts, labels): groups.setdefault(l, []).append(v)
    cen = {l: [sum(p[k] for p in ps) / len(ps) for k in range(3)] for l, ps in groups.items()}
    if human:
        head = min(cen, key=lambda l: (cen[l][1], -len(groups[l])))  # y points down
    else:
        ys = [p[1] for p in verts]; zs = [p[2] for p in verts]
        front = min(zs) + 0.3 * (max(zs) - min(zs)); mid = (min(ys) + max(ys)) / 2
        near = [l for l in cen if cen[l][2] <= front and cen[l][1] <= mid] or list(cen)
        head = max(near, key=lambda l: len(groups[l]))
    return [f"{'bone' if skeletal else 'label'}_{head:03d}"]


def write(folder, pal, display, clips, loops, extra, behaviour, height, kind, rows):
    folder.mkdir(parents=True, exist_ok=True)
    gaits = [c for c in ("Walk", "Run") if c in clips]
    meshscale = 1.0 if 1.2 <= height <= 2.4 else round(min(2.4, max(1.2, height)) / height, 4)
    spec = {"pal": pal, "model": "model.glb", "forward": "-Y",
            "clips": {c: c for c in clips}, "inPlace": gaits,
            "osrs": dict(kind, clips=clips, loops=sorted(loops))}
    old = folder / "character.json"
    if old.exists():  # hand settings survive a redraft
        kept = json.loads(old.read_text()).get("osrs", {})
        hidden = kept.get("hideFaceGroups")
        if hidden: spec["osrs"]["hideFaceGroups"] = sorted(set(hidden) | set(spec["osrs"].get("hideFaceGroups", [])))
        if kept.get("glow"): spec["osrs"]["glow"] = kept["glow"]
    cfg = {"_comment": f"Drafted by sources/osrs/draft.py ({display}); edit freely, re-run make_osrs_pet.sh.",
           "displayName": display, "animSet": pal, "meshScale": meshscale, "floats": False,
           "defaults": {"facing": "directional", "loop": False, "fadeIn": 0.2}, "directionalYawDegrees": 40,
           "maxPelvisLift": {}, "rootTravelScale": {}, "stripRootMotion": [],
           "groups": behaviour["groups"], "idleClip": "Idle", "idleVariants": behaviour["idleVariants"],
           "clips": {"Idle": {"facing": "front", "loop": True}, **{g: {"loop": True, "yawDegrees": 90} for g in gaits},
                     **{grp["loop"]: {"loop": True} for grp in behaviour["groups"].values()}},
           "locomotion": {g: {"weight": 3 if g == "Walk" else 1, "speed": round(WALK_SPEED if g == "Walk" else RUN_SPEED, 3),
                              "maxSeconds": None if g == "Walk" else 3} for g in gaits},
           "wander": {"chance": 0.35, "seconds": [2.5, 5], "minDistanceMetres": 1.5, "depthChance": 0.3},
           "surprise": {"intervalSeconds": [60, 180], "loopCount": [1, 2], "minSeconds": 3, "exclude": []},
           "input": behaviour["input"]}
    if behaviour.get("submenus"): cfg["submenus"] = behaviour["submenus"]
    cfg.update(extra)
    (folder / "character.json").write_text(json.dumps(spec, indent=2) + "\n")
    (folder / "clip-config.json").write_text(json.dumps(cfg, indent=2) + "\n")
    (folder / "clips.txt").write_text("\n".join(rows) + "\n")
    print(f"DRAFT_OK {folder}: {len(clips)} clips ({', '.join(clips)})")


def draft_npc(folder, cache, args, nm):
    npcs = defs.load_all(cache, 9, defs.npc); seqs = defs.load_all(cache, 12, defs.sequence)
    n = pick_npc(npcs, " ".join(args.name), args.id)
    index = skeleton_index(cache, seqs)
    skel = index.get(n["stand"]); human = {i for i, k in index.items() if k == index.get(names.HUMAN_IDLE)}
    clips = {"Idle": n["stand"]}
    for key, clip in (("walk", "Walk"), ("run", "Run")):
        if n.get(key) not in (None, 65535, n["stand"]): clips[clip] = n[key]
    names_of = {c: nm.get(s, f"SEQ_{s}") for c, s in clips.items()}
    rows = [f"# Animations made for {n['name']}'s skeleton: id, name, seconds. Add one by putting",
            "# \"Name\": id in character.json's osrs.clips (and a line for it in clip-config.json if needed)."]
    if skel == index.get(names.HUMAN_IDLE):
        emotes = emote_clips(folder, cache, nm, human)
        clips.update({c: s for c, s in emotes if c not in clips})
        behaviour = human_config(clips, emotes, [])
        rows.append("# Human: every player animation fits (ids and names in .tools/osrs/AnimationID.java); emotes come from")
        rows.append(f"# {folder / 'emotes.txt'} if present, else {names.SHARED / 'emotes.txt'}.")
    else:
        prefix = "_".join(nm.get(n["stand"], "").split("_")[:-1]) + "_" if "_" in nm.get(n["stand"], "") else ""
        for sid in sorted(i for i, k in index.items() if k == skel):
            s = seqs[sid]; label = nm.get(sid, f"SEQ_{sid}")
            secs = seconds(s); used = sid in clips.values()
            rows.append(f"{sid:6} {label:48} {secs:5.1f}s")
            if used or not s["frames"] and s["maya"] < 0: continue
            if secs < 0.1 or sum(s["lengths"]) * 0.02 > MAX_SECONDS or EXCLUDE & words_of(label) or "CHAT" in label:
                continue
            c = names.clip_name(label, prefix)
            while c in clips: c += "2"
            clips[c] = sid; names_of[c] = label
        behaviour = creature_config(clips, names_of)
    loops = {"Idle", "Walk", "Run"} & set(clips) | {g["loop"] for g in behaviour["groups"].values()}
    height = idle_height(cache, n)
    scale = (n["widthScale"] / 128, n["heightScale"] / 128, n["widthScale"] / 128)
    look = look_bone(cache, [(m, n["recolor"], 0) for m in n["models"]], [], scale, skel == index.get(names.HUMAN_IDLE))
    kind = {"npc": n["id"]}
    hidden = ground_effects(cache, n)
    if hidden:
        kind["hideFaceGroups"] = hidden
        print(f"NOTE hiding ground effects (face groups {hidden}): shadows, ripples and the like")
    write(folder, camel(" ".join(args.name)), n["name"], clips, loops, {"lookBones": look}, behaviour, height,
          kind, rows)


def ground_effects(cache, n):
    """Face groups that are effects lying on the floor (drawn shadows, water ripples and their droplets): the
    game draws them see-through, and solid they'd be blobs on the desktop, so the draft hides them. A flat group on
    the floor counts when it's wide (over 0.3 m; soles and paws are smaller) in colours the body doesn't
    use (a big creature's feet share the body's), and so do small ones in those same colours (droplets)."""
    import model as mdl
    out = set()
    for mid in n["models"]:
        m = mdl.load(cache, mid)
        if not m.tgroups: continue
        pts, cols = {}, {}
        for f in range(m.nf):
            g = m.tgroups[f]
            pts.setdefault(g, []).extend((m.vx[v] / 128, -m.vy[v] / 128, m.vz[v] / 128) for v in (m.f1[f], m.f2[f], m.f3[f]))
            cols.setdefault(g, set()).add(m.colors[f])
        flat = {g for g, ps in pts.items() if g and max(p[1] for p in ps) - min(p[1] for p in ps) < 0.03
                and max(p[1] for p in ps) < 0.05}
        body = set().union(*(cols[g] for g in cols if g not in flat))
        width = lambda ps: max(max(p[0] for p in ps) - min(p[0] for p in ps), max(p[2] for p in ps) - min(p[2] for p in ps))
        wide = {g for g in flat if width(pts[g]) > 0.3 and not cols[g] & body}
        effect = set().union(*(cols[g] for g in wide)) if wide else set()
        out |= wide | {g for g in flat if cols[g] <= effect}
    return sorted(out)


def idle_height(cache, n):
    import model as mdl
    ys = []
    for mid in n["models"]:
        m = mdl.load(cache, mid); ys += [-y * n["heightScale"] / 128 for y in m.vy]
    return (max(ys) - min(ys)) / 128 if ys else 1.0


def draft_player(folder, cache, args, nm):
    outfit = player.read_outfit(folder / "outfit.txt")
    seqs = defs.load_all(cache, 12, defs.sequence); index = skeleton_index(cache, seqs)
    human = {i for i, k in index.items() if k == index.get(names.HUMAN_IDLE)}
    items = defs.load_all(cache, 10, defs.item); kits = defs.load_all(cache, 3, defs.kit)
    parts, recolours, worn = player.assemble(outfit, kits, items)
    clips = {"Idle": 808, "Walk": 819, "Run": 824}
    by_name = {v: k for k, v in nm.items()}
    def seq_of(v): return int(v) if v.isdigit() else by_name.get(v)
    weapon = next((it for it in worn if it.get("wearPos1") == 3), None)
    attacks = []
    if weapon:
        stance, found = names.weapon_animations(weapon, nm, human)
        if outfit.stance == "auto":
            clips.update(stance)
            print(f"STANCE {weapon['name']}: " + (", ".join(f"{k} {nm.get(v)}" for k, v in stance.items()) or "none found, unarmed stance (set stance: to choose)"))
        if outfit.combat == "auto":
            attacks = found
            print(f"COMBAT {weapon['name']}: " + (", ".join(f"{c} ({s})" for c, s in found) or "none found (set combat: to choose)"))
    if outfit.stance not in ("auto", ""):
        sid = seq_of(outfit.stance)
        if sid is None: raise SystemExit(f"stance: no animation {outfit.stance!r}")
        clips["Idle"] = sid
    if outfit.combat not in ("auto", "none", ""):
        attacks = []
        for v in outfit.combat.split(","):
            sid = seq_of(v.strip())
            if sid is None: raise SystemExit(f"combat: no animation {v.strip()!r}")
            attacks.append((names.clip_name(nm.get(sid, f"Seq{sid}")), sid))
    attacks = [("Attack" + (str(k + 1) if k else ""), s) for k, (_, s) in enumerate(attacks)]
    for c, s in attacks: clips.setdefault(c, s)
    emotes = emote_clips(folder, cache, nm, human, outfit.emotes)
    clips.update({c: s for c, s in emotes if c not in clips})
    behaviour = human_config(clips, emotes, [c for c, _ in attacks])
    rows = ["# Player character: any human animation can be added as \"Name\": id in character.json's osrs.clips",
            "# (ids and names in .tools/osrs/AnimationID.java). Worn: " + ", ".join(f"{i['name']} ({i['id']})" for i in worn)]
    pal = camel(" ".join(args.name))
    write(folder, pal, " ".join(args.name).title(), clips, {"Idle", "Walk", "Run"} | {g["loop"] for g in behaviour["groups"].values()},
          {"lookBones": look_bone(cache, parts, recolours, (1, 1, 1), True)}, behaviour, 1.6, {"player": "outfit.txt"}, rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("name", nargs="+"); ap.add_argument("--id", type=int)
    ap.add_argument("--player", action="store_true", help="start a player character: writes an outfit.txt to fill in")
    ap.add_argument("--redraft", action="store_true", help="replace an existing draft")
    args = ap.parse_args()
    folder = ROOT / "characters" / slug(" ".join(args.name))
    if args.player and not (folder / "outfit.txt").exists():
        folder.mkdir(parents=True, exist_ok=True); (folder / "outfit.txt").write_text(player.TEMPLATE)
        print(f"OUTFIT {folder / 'outfit.txt'}: fill it in, then run make_osrs_pet.sh {' '.join(args.name)!r} again")
        return 3
    if (folder / "character.json").exists() and not args.redraft:
        outfit = folder / "outfit.txt"
        if outfit.exists() and outfit.stat().st_mtime > (folder / "character.json").stat().st_mtime:
            print(f"NOTE {outfit} changed since the draft; re-run with --redraft to pick up a new weapon or emotes")
        print(f"DRAFT_KEPT {folder}")
        print(f"FOLDER {folder}")
        return 0
    cache = Cache(); nm = names.animation_names()
    if (folder / "outfit.txt").exists(): draft_player(folder, cache, args, nm)
    else: draft_npc(folder, cache, args, nm)
    print(f"FOLDER {folder}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
