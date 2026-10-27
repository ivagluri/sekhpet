"""Names for things the cache leaves unnamed: animations (RuneLite's AnimationID list), the emote tab, and the
stances and attacks that go with a weapon (server-side in the game, so matched here by name)."""
import json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / ".tools" / "osrs"
SHARED = ROOT / "characters" / "_osrs"   # the user's shared lists (gitignored with characters/)
HUMAN_IDLE = 808                          # HUMAN_READY: its framemap is the human skeleton

EMOTE_ENUM = 1000  # config enum: emote tab slot -> name
# Emote names whose words don't appear in the animation's name
EMOTE_ALIASES = {
    "Jig": "EMOTE_DANCE_SCOTTISH", "Spin": "EMOTE_DANCE_SPIN", "Headbang": "EMOTE_DANCE_HEADBANG",
    "Raspberry": "EMOTE_YA_BOO_SUCKS", "Idea": "EMOTE_LIGHTBULB", "Stamp": "EMOTE_STAMPFEET",
    "Flap": "EMOTE_PANIC_FLAP", "Lean": "EMOTE_MIME_LEAN", "Climb Rope": "EMOTE_CLIMBING_ROPE",
    "Sit up": "EMOTE_SITUPS_5", "Push up": "EMOTE_PUSHUPS_5", "Star jump": "EMOTE_STARJUMP_5",
    "Jog": "EMOTE_RUN_ON_SPOT", "Sit down": "EMOTE_SIT", "Jump for Joy": "EMOTE_JUMP_WITH_JOY",
    "Salute": "EMOTE_FREMMENIK_SALUTE", "Fortis Salute": "EMOTE_VARLAMORE_SALUTE",
    "Zombie Walk": "ZOMBIE_WALK_EMOTE", "Skill Cape": None,  # each cape has its own
    # Event unlocks, named after their event rather than the emote
    "Smooth dance": "BDAY17_BLING", "Rabbit Hop": "RABBIT_EMOTE", "Premier Shield": "PREMIER_CLUB_EMOTE",
    "Crab dance": "HUMAN_EMOTE_CRABDANCE", "Uri transform": "EMOTE_URI_BRIEFCASE",
    "Zombie Hand": "HW07_ARM_FROM_THE_GROUND_EMOTE", "Scared": "TERRIFIED_EMOTE",
    "Goblin Salute": "HUMAN_CAVE_GOBLIN_DANCE",  # the id after Goblin Bow's, from the same quest
}
# Emotes whose animation isn't known for sure: candidates to try, shown in the emote list
EMOTE_CANDIDATES = {"Crazy dance": "BDAY17_STYLE or BDAY17_LASSO (2017 birthday event)",
                    "Uri transform": "the game also turns you into Uri for it",
                    "Goblin Salute": "named a dance; next to Goblin Bow"}
STOP = {"FOR", "THE", "OF", "A", "AND"}
# Words in an item name that say what it's made of rather than what it is
MATERIALS = {"BRONZE", "IRON", "STEEL", "BLACK", "WHITE", "MITHRIL", "ADAMANT", "RUNE", "DRAGON", "GRANITE",
             "BLESSED", "CORRUPTED", "CRYSTAL", "OF", "THE", "(P)", "(P+)", "(P++)", "(KP)", "(G)", "(T)", "(OR)"}
ATTACK_WORDS = ("ATTACK", "SPECIAL", "SP_ATTACK", "SLASH", "STAB", "CRUSH", "LUNGE", "HACK", "LASH", "SMASH",
                "POUND", "FIRE", "SHOOT", "SWING", "JAB", "SPEC")


def animation_names():
    """{sequence id: NAME} from RuneLite's gameval AnimationID.java (fetched by make_osrs_pet.sh)."""
    path = TOOLS / "AnimationID.java"
    if not path.exists():
        raise SystemExit(f"{path} is missing: run sources/osrs/make_osrs_pet.sh once (it downloads it)")
    return {int(v): k for k, v in re.findall(r"int (\w+) = (\d+);", path.read_text())}


def clip_name(name, prefix=""):
    """CAT_SLEEP_READY (prefix CAT_) -> SleepReady; names must be plain words for the pipeline."""
    if prefix and name.startswith(prefix) and len(name) > len(prefix):
        name = name[len(prefix):]
    words = [w for w in re.split(r"[_\W]+", name) if w]
    return "".join(w[:1].upper() + w[1:].lower() for w in words) or "Clip"


def common_prefix(names):
    """The shared leading words of a skeleton's animation names (CAT_ for the cat's)."""
    parts = [n.split("_") for n in names if n]
    if len(parts) < 2: return ""
    out = []
    for words in zip(*parts):
        if len(set(words)) != 1: break
        out.append(words[0])
    return "_".join(out) + "_" if out else ""


def _tokens(s):
    return [w for w in re.split(r"[^A-Z0-9]+", s.upper()) if w]


def match_emotes(emotes, names, human):
    """[(emote name, sequence id or None)]: each emote tab name matched to a human-skeleton animation."""
    by_name = {n: i for i, n in names.items() if i in human}
    out = []
    for emote in emotes:
        alias = EMOTE_ALIASES.get(emote, "")
        if alias is None or alias in by_name:
            out.append((emote, by_name.get(alias))); continue
        want = [w for w in _tokens(emote) if w not in STOP]
        best = None
        for n, i in by_name.items():
            words = _tokens(n)
            if "LOOP" in words or "WALKMERGE" in words or "SPOTANIM" in words or not all(w in words for w in want):
                continue
            score = ("EMOTE" in words, n.startswith("HUMAN_"), -len(words), -i)
            if best is None or score > best[0]: best = (score, i)
        out.append((emote, best[1] if best else None))
    return out


def _emote_line(emote, sid, names):
    if sid is None:
        hint = EMOTE_CANDIDATES.get(emote, "put an animation name or id here")
        return f"# {emote:<22} # no animation found ({hint})"
    known = emote in EMOTE_ALIASES or "EMOTE" in _tokens(names[sid])
    note = "" if known and emote not in EMOTE_CANDIDATES else f"  (a guess: {EMOTE_CANDIDATES.get(emote, 'check it')})"
    return f"{emote:<24} # {names[sid]} ({sid}){note}"


def emote_file(path, cache_emotes, names, human):
    """Write the commented emote list (each tab emote with its match); return its path. An existing list
    is kept as the user left it, except that emotes it couldn't match before are filled in once found."""
    matched = match_emotes(cache_emotes, names, human)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = ["# The emote tab's emotes (from the game cache) and the animation each plays as a pet clip.",
                 "# Comment out (#) any you don't want. A character folder's own emotes.txt replaces this list.", ""]
        path.write_text("\n".join(lines + [_emote_line(e, sid, names) for e, sid in matched]) + "\n")
        return path
    found = {e: sid for e, sid in matched if sid is not None}
    lines = path.read_text().splitlines(); changed = False
    for k, line in enumerate(lines):  # fill in emotes found since, and redo guesses that have a better match now
        m = re.match(r"#\s*(.+?)\s+# no animation found", line) or re.match(r"(\S.*?)\s+# .*\(a guess", line)
        if m and m.group(1) in found:
            new = _emote_line(m.group(1), found[m.group(1)], names)
            if new != line: lines[k] = new; changed = True
    if changed:
        path.write_text("\n".join(lines) + "\n")
    return path


def read_emotes(path, names, human):
    """Emote lines -> [(clip name, sequence id)]. A line is an emote name (matched as above), an
    animation name, or an id; text after # is ignored."""
    out = []
    by_name = {n: i for i, n in names.items()}
    for raw in path.read_text().splitlines():
        line = raw.split("#")[0].strip()
        if not line: continue
        if line.isdigit(): sid = int(line)
        elif line in by_name: sid = by_name[line]
        else: sid = match_emotes([line], names, human)[0][1]
        if sid is None:
            print(f"WARNING emote {line!r}: no animation found, skipped"); continue
        out.append((clip_name(line if not line.isdigit() else names.get(sid, f"Seq{sid}"), "EMOTE_"), sid))
    return out


def _java_regex(r):
    """Java allows look-behinds of different lengths in one group; Python wants one per length."""
    return re.sub(r"\(\?<!([^()]*)\)", lambda m: "".join(f"(?<!{a})" for a in m.group(1).split("|")), r)


def weapon_idles():
    path = TOOLS / "weapon-idles.json"
    return json.loads(path.read_text())["anims"] if path.exists() else []


def weapon_animations(item, names, human):
    """{'Idle', 'Walk', 'Run': id} stance clips found for a weapon, and [(clip name, id)] attacks.
    The idle comes from Fashionscape's hand-kept weapon table; walk/run/attacks from animation names."""
    iname = (item.get("name") or "").lower()
    stance = {}
    for e in weapon_idles():
        if (item["id"] in e.get("item_ids", []) or iname in e.get("exact", [])
                or any(c in iname for c in e.get("contains", []))
                or any(re.search(_java_regex(r), iname) for r in e.get("regex", []))):
            stance["Idle"] = e["id"]; break
    words = [w for w in _tokens(iname) if w not in MATERIALS]
    if not words: return stance, []
    cands = []
    for i, n in names.items():
        if i not in human: continue
        nw = _tokens(n)
        hits = sum(1 for w in words if w in nw)
        if any(w in MATERIALS and w not in _tokens(iname) for w in nw):
            continue  # another material's version (a dragon scimitar's special, for a rune one)
        if hits and words[-1] in nw:  # the last word names the weapon (whip, scimitar, crossbow)
            cands.append((hits, i, n, nw))
    cands.sort(key=lambda c: (-c[0], c[1]))
    for key, test in (("Walk", lambda nw: ("WALK" in nw or "WALK_F" in "_".join(nw)) and not {"B", "L", "R"} & set(nw)),
                      ("Run", lambda nw: "RUN" in nw or "RUNNING" in nw)):
        for _, i, n, nw in cands:
            if test(nw) and key not in stance:
                stance[key] = i
    attacks = [(clip_name(n, ""), i) for _, i, n, nw in cands
               if any(w in nw for w in ATTACK_WORDS) and "SPOTANIM" not in nw and "SPOT" not in nw and "TRAIL" not in nw]
    return stance, attacks[:4]
