"""Generate work/<pal>/clip-config.json from a pal's probe and blueprint.

  python3 sources/palworld/make_pal_config.py <Pal> [--anims <Base>]

Inputs: work/<pal>/probe.json (pipeline/probe_pal.py), the pal's blueprint
mesh scale (read with the converter's --inspect mode), the paldeck name, and the
optional hand-made overrides in sources/palworld/overrides/<pal>.json, which are merged last
(dicts merge, lists replace, except `exclude`, which accumulates; null removes a key).

The rules (see PIPELINE.md):
- Idle and RestNN face the viewer; everything else turns to a directional view.
- Start/StartLoop/Action/Action1.../UpLoop/ActionLoop/Loop/DownLoop/End clips are grouped by stem; a group
  with no loop clip (Start, Action1, Action2, End) plays through once.
- Walk/Trot/Transport/Run/Sprint (+ swim gaits) become wander travel.
- Work clips (the blueprint's work actions: CommonWork, Mining, Deforest...) loop.
- Clips with large planar root travel are stripped and replayed (scaled to <= 1.5 m).
- A large pelvis launch is capped; a get-up that starts high in the air is excluded.
- Additive clips (Hit) are excluded.
- The on-screen standing height is the game's (mesh scale x model height), clamped
  to 1.2-2.4 m.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIN_HEIGHT, MAX_HEIGHT = 1.2, 2.4
GAITS = {  # weight, maxSeconds, the game's speed field (cm/s) for that gait
    'Walk': (5, None, 'WalkSpeed'), 'Trot': (4, None, 'WalkSpeed'), 'Transport': (1, None, 'TransportSpeed'),
    'Run': (2, 4, 'RunSpeed'), 'Sprint': (1, 3, 'RideSprintSpeed'),
    'Walk_Swim': (1, None, 'SwimSpeed'), 'Run_Swim': (1, None, 'SwimDashSpeed'),
}
PARTS = ['Start', 'StartLoop', 'Action', 'UpLoop', 'ActionLoop', 'Loop', 'DownLoop', 'End']


def merge(base, extra):
    for key, value in extra.items():
        if key == 'exclude' and isinstance(value, list):
            base[key] = sorted(set(base.get(key, [])) | set(value))
        elif value is None:
            base.pop(key, None)
        elif isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base


def blueprint_scale(pal, anims):
    """CharacterMesh0 RelativeScale3D from BP_<pal>, or 1."""
    raw = ROOT / 'work' / pal.lower() / 'raw'
    found = list(raw.rglob(f'BP_{pal}.uasset'))
    if not found:
        return 1.0, 'no blueprint found'
    package = found[0].relative_to(raw).as_posix()
    out = ROOT / 'work' / pal.lower() / 'blueprint.json'
    env = {'DOTNET_CLI_HOME': str(ROOT / '.tools/dotnet-home'), 'NUGET_PACKAGES': str(ROOT / '.tools/nuget'),
           'DOTNET_CLI_TELEMETRY_OPTOUT': '1', 'PATH': '/usr/bin:/bin'}
    subprocess.run([str(ROOT / '.tools/dotnet/dotnet'), str(ROOT / 'sources/palworld/converter/bin/Release/net10.0/Converter.dll'),
                    str(raw), str(out), str(ROOT / '.tools/Palworld-Mappings.usmap'), '--inspect', package],
                   check=True, capture_output=True, env=env)
    exports = next(iter(json.loads(out.read_text()).values()))
    for export in exports:
        if export.get('Name', '').startswith('CharacterMesh0'):
            scale = export.get('Properties', export).get('RelativeScale3D')
            if scale:
                return float(scale['X']), f'BP_{pal} CharacterMesh0 RelativeScale3D'
    return 1.0, f'BP_{pal} leaves the mesh at 1.0'


# The game's work actions; their montages repeat for as long as the pal works.
WORK_ACTIONS = {'CommonWork', 'Architecture', 'Mining', 'Deforest', 'Watering', 'Feeding', 'Cooking', 'Cool'}
WORK_CLIPS = {'CommonWork', 'Architecture', 'Mining', 'Deforest', 'Watering', 'Planting', 'Cooking', 'Cooling'}


def work_clips(pal, names):
    """Clips the blueprint's ActionMontageMap (in the blueprint.json that
    blueprint_scale wrote) plays for work, minus any it also plays for something else.
    A variant inherits its map from a base blueprint that isn't extracted, so without
    one the usual work clip names stand in."""
    path = ROOT / 'work' / pal.lower() / 'blueprint.json'
    exports = next(iter(json.loads(path.read_text()).values())) if path.exists() else []
    if not any('ActionMontageMap' in export.get('Properties', {}) for export in exports):
        return WORK_CLIPS & names
    work, other = set(), set()
    for export in exports:
        for entry in export.get('Properties', {}).get('ActionMontageMap', []):
            montage = (entry['Value'] or {}).get('ObjectName') or ''
            clip = max((n for n in names if montage.endswith(f"_{n}'")), key=len, default=None)
            if clip:
                (work if entry['Key'].split('::')[-1] in WORK_ACTIONS else other).add(clip)
    return work - other


def split_parts(name):
    """Every (stem, part) reading of a start/loop/end clip name. Accepts `Stem_Part`
    in any case and `StemPart` with a capitalised part (LargeDownStart, JumpStart),
    so a word that merely ends in "end" doesn't match."""
    readings = []
    # Numbered actions chain in order: MoonBlade_Start, _Action1, _Action2, _End is one move.
    numbered = re.fullmatch(r'(.+)_Action_?(\d+)', name, re.IGNORECASE)
    if numbered:
        return [(numbered.group(1), f'Action{int(numbered.group(2)):02d}')]
    for part in sorted(PARTS, key=len, reverse=True):
        match = re.fullmatch(rf'(.+)_({part})', name, re.IGNORECASE) or re.fullmatch(rf'(.{{3,}}?)({part})', name)
        if match and match.group(1) not in ('Idle', 'Run', 'Walk'):
            readings.append((match.group(1), part))
    return readings


def find_groups(names):
    readings = {name: split_parts(name) for name in names}
    support = {}
    for options in readings.values():
        for stem, _ in options:
            support[stem] = support.get(stem, 0) + 1
    stems = {}
    for name, options in readings.items():
        if options:
            # LargeDownLoop reads as Large+DownLoop or LargeDown+Loop: take the stem
            # its sibling clips share (ties keep the longer part).
            stem, part = max(options, key=lambda o: support[o[0]])
            stems.setdefault(stem, {})[part] = name
    # A numbered sub-stem continues its parent: TrickShow_Start -> TrickShow_01 ->
    # TrickShow_01_Loop -> TrickShow_01_End is one sequence, with the bare
    # `TrickShow_01` clip as its action.
    for stem in sorted(stems, key=len, reverse=True):
        parent = re.fullmatch(r'(.+)_\d+', stem)
        if parent and parent.group(1) in stems:
            child = stems.pop(stem)
            merged = stems[parent.group(1)]
            if stem in names:
                child.setdefault('Action', stem)
            for part, clip in child.items():
                merged.setdefault(part, clip)
    # A bare numbered clip beside a group (BrutalMachete_01, Breaching_01) is one of its actions.
    for stem, parts in stems.items():
        for name in names:
            number = re.fullmatch(rf'{re.escape(stem)}_(\d+)', name)
            if number and name not in parts.values():
                parts[f'Action{int(number.group(1)):02d}'] = name
    groups = {}
    for stem, parts in stems.items():
        if len(parts) < 2:
            continue
        loop = next((parts[p] for p in ('ActionLoop', 'Loop', 'DownLoop', 'StartLoop') if p in parts), None)
        if loop is None and stem in names and stem not in parts.values():
            loop = stem  # SleepStart, Sleep, SleepEnd: the bare clip is the held part
        # Actions in number order (Breaching_01 before Breaching_02, whichever way each was found).
        actions = sorted((parts[p] for p in parts if p == 'Action' or re.fullmatch(r'Action\d+', p)),
                         key=lambda clip: int(m.group(1)) if (m := re.search(r'(\d+)$', clip)) else 0)
        start = [clip for clip in [parts.get('Start'), parts.get('StartLoop'), *actions, parts.get('UpLoop')]
                 if clip and clip != loop]
        end = [parts['End']] if 'End' in parts else []
        group = {'start': start, 'loop': loop, 'end': end}
        if loop is None:  # no loop (Start, actions, End): play them back to back, once
            group.update(start=start[:-1], loop=start[-1], loopCount=[1, 1])
        elif loop.endswith(('DownLoop', 'UpLoop')):
            group['loopCount'] = [1, 2]  # a fall or hold, not something to repeat
        elif stem.startswith('Skill') and loop.endswith('Loop'):
            group['loopCount'] = [3, 6]
        groups[stem.replace('Skill_', '')] = group
    # Fallbacks for the named Palworld sets when detection found nothing.
    if 'Sleep' not in groups and {'SleepStart', 'SleepLoop'} <= names:
        groups['Sleep'] = {'start': ['SleepStart'], 'loop': 'SleepLoop', 'end': ['SleepEnd'] if 'SleepEnd' in names else []}
    if 'Jump' not in groups and 'JumpLoop' in names:
        groups['Jump'] = {'start': [], 'loop': 'JumpLoop', 'end': ['JumpEnd'] if 'JumpEnd' in names else []}
    if {'Carrying_Start', 'Carrying'} <= names:
        groups.pop('Carrying', None)
        groups['Carrying'] = {'start': ['Carrying_Start'], 'loop': 'Carrying', 'end': []}
    return groups


def main():
    pal = sys.argv[1]
    anims = sys.argv[sys.argv.index('--anims') + 1] if '--anims' in sys.argv else pal
    probe = json.loads((ROOT / 'work' / pal.lower() / 'probe.json').read_text())
    clips = probe['clips']
    names = set(clips)
    rows = {row[3]: row for row in json.loads((ROOT / 'work/tables/paldeck.json').read_text())}
    display = rows[pal][2] if pal in rows else pal
    # The paldeck number as the game shows it: 002, or 005B for a variant.
    number = f'{rows[pal][0]:03d}{rows[pal][1]}' if pal in rows and rows[pal][0] > 0 else None

    game_scale, scale_source = blueprint_scale(pal, anims)
    model_height = probe['idleMaxZ']
    game_height = model_height * game_scale
    shown = min(max(game_height, MIN_HEIGHT), MAX_HEIGHT)
    mesh_scale = round(shown / model_height, 4)
    floats = probe['idleMinZ'] > 0.15

    groups = find_groups(names)
    grouped = {c for g in groups.values() for c in g['start'] + [g['loop']] + g['end']}
    working = work_clips(pal, names)
    settings = {}
    for name in sorted(names):
        clip = {}
        if name == 'Idle':
            clip = {'facing': 'front', 'loop': True, 'fadeIn': 0.4}
        elif re.fullmatch(r'Rest\d+', name):
            clip = {'facing': 'front', 'fadeIn': 0.45}
        elif name in GAITS:
            clip = {'loop': True, 'yawDegrees': 90}
        elif name in grouped and name.endswith('Loop') or name in ('Carrying', 'SleepLoopTogether'):
            clip = {'loop': True}
            if name.endswith(('ActionLoop', 'StartLoop', 'UpLoop', 'DownLoop')) or (name.endswith('_Loop') and name in grouped):
                clip['fadeIn'] = 0.1
            if name == 'JumpLoop':
                clip['fadeIn'] = 0.15
        elif name in working:
            clip = {'loop': True}
        elif name == 'Damage':
            clip = {'fadeIn': 0.15}
        elif name == 'Petting':
            clip = {'fadeIn': 0.3}
        if clip:
            settings[name] = clip

    # Root travel: strip it from the animation and replay it on screen, at most 1.5 m.
    travel_scale, strip = {}, []
    for name, info in clips.items():
        distance = (info['rootEnd'][0] ** 2 + info['rootEnd'][1] ** 2) ** 0.5
        if distance > 0.3 and name not in GAITS:
            strip.append(name)
            travel_scale[name] = round(min(1.0, 1.5 / distance), 3)
            settings.setdefault(name, {})['yawDegrees'] = 30 if 'Step' in name or 'Dodge' in name else 60

    exclude = {name for name, info in clips.items() if info['additive'] != 'AAT_None'}
    exclude |= {name for name in ('Carrying', 'Carrying_Start') if name in names}  # the flop
    pelvis_cap = {}
    for name, info in clips.items():
        if info['pelvisLift'] > max(1.0, 0.5 * model_height) and not floats:
            if name.lower().startswith('getup'):
                exclude.add(name)  # starts high in the air; capping sinks it into the floor
            else:
                pelvis_cap[name] = round(0.4 * model_height, 2)

    # Reactions: petting with a small chance of a flinch; a signature skill on double-click.
    click = [{'clip': c, 'weight': w} for c, w in (('Petting', 87), ('Damage', 13)) if c in names]
    if not click:
        click = [{'clip': c, 'weight': 1} for c in ('Encount', 'Damage') if c in names][:1]
    singles = sorted(n for n in names - grouped - exclude
                     if n.startswith('Skill') and 0.8 <= clips[n]['duration'] <= 4)
    double = singles[0] if singles else next((c for c in ('Encount', 'Rest01') if c in names and c not in {e['clip'] for e in click}), None)

    # Game speeds are for the game-scaled body; convert to model metres per second.
    tables = json.loads((ROOT / 'work/tables/tables.json').read_text())
    rows = next(v for k, v in tables.items() if 'MonsterParameter' in k)[0]['Rows']
    # A pal built under its mesh name (no stats row of its own) moves like the base pal
    # whose animations it shares.
    params = rows.get(pal) or rows.get(anims, {})
    locomotion = {}
    for gait, (weight, max_seconds, field) in GAITS.items():
        if gait in names:
            entry = {'weight': weight}
            if params.get(field):
                entry['gameSpeed'] = round(params[field] / 100 / game_scale, 3)
            if max_seconds:
                entry['maxSeconds'] = max_seconds
            locomotion[gait] = entry

    config = {
        '_comment': f'Generated by sources/palworld/make_pal_config.py for {display} ({pal}); hand edits go in sources/palworld/overrides/{pal.lower()}.json.',
        'displayName': display,
        'paldeckNo': number,
        'animSet': anims,
        'gameScale': game_scale,
        '_meshScale': f'{scale_source} = {game_scale}; game height {game_height:.2f} m, shown {shown:.2f} m '
                      f'(clamped to {MIN_HEIGHT}-{MAX_HEIGHT} m).',
        'meshScale': mesh_scale,
        'floats': floats,
        'defaults': {'facing': 'directional', 'loop': False, 'fadeIn': 0.35},
        'directionalYawDegrees': 40,
        'clips': settings,
        'maxPelvisLift': pelvis_cap,
        'rootTravelScale': travel_scale,
        'stripRootMotion': strip,
        'groups': groups,
        'idleClip': 'Idle',
        'locomotion': locomotion,
        'wander': {'chance': 0.35, 'seconds': [2.5, 6], 'minDistanceMetres': 1.5, 'depthChance': 0.5},
        'surprise': {'intervalSeconds': [60, 180], 'loopCount': [2, 4], 'minSeconds': 6, 'exclude': sorted(exclude)},
        # A pal's Carrying clip is a flop onto its side, so being held loops the
        # jump and letting go lands it.
        'input': {'singleClick': click, 'doubleClick': double,
                  'dragGroup': 'Jump' if 'Jump' in groups else None,
                  'dropGroup': 'Jump' if 'Jump' in groups else None},
    }
    overrides = ROOT / 'sources/palworld/overrides' / f'{pal.lower()}.json'
    if overrides.exists():
        extra = json.loads(overrides.read_text())
        merge(config, {k: v for k, v in extra.items() if k != 'exclude'})
        # `allowLarge` re-enables clips the bounds check excluded, accepting a bigger window.
        config['surprise']['exclude'] = sorted((set(config['surprise']['exclude']) | set(extra.get('exclude', [])))
                                               - set(extra.get('allowLarge', [])))
    assert 'Idle' in names, f'{pal} has no Idle clip'
    path = ROOT / 'work' / pal.lower() / 'clip-config.json'
    if '--out' in sys.argv:
        path = Path(sys.argv[sys.argv.index('--out') + 1])
    elif path.exists() and 'Generated by' not in path.read_text():
        # A hand-made config is kept as it is (--out writes a generated one elsewhere).
        print(f'{pal}: keeping the hand-made {path.name}')
        return
    path.write_text(json.dumps(config, indent=2) + '\n')
    print(f'{display}: game {game_height:.2f} m -> shown {shown:.2f} m (meshScale {mesh_scale}); '
          f'{len(groups)} groups, {len(locomotion)} gaits, double-click {double}, floats={floats}; wrote {path.name}')


if __name__ == '__main__':
    main()
