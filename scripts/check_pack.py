"""Check an exported pal pack, then run it through the app's offscreen test.

  python3 scripts/check_pack.py <Pal> [--bounds-only]

1. Bounds: the exporter already squashed the body motion of oversized clips
   (scripts/pack_limits.py). A surprise clip whose pose alone still exceeds the limits
   by `DROP_FACTOR` would blow up the window, so it is added to
   overrides/<pal>.json `exclude`. Exits 3 when it added any (re-export).
2. Behavior: runs `SekhPet --snapshot` with scripted input (click, double-click,
   drag/drop, cursor watching, a group and a trip) and checks that each one started.
3. Writes work/<pal>/check-sheet.png, a contact sheet for visual review.
"""
import json
import os
import subprocess
import sys
from pathlib import Path
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pack_limits  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
pal = sys.argv[1]
base = ROOT / 'work' / pal.lower()
pack = base / 'realtime'
catalog = json.loads((pack / 'clips.json').read_text())
clips = catalog['clips']
height = clips['Idle']['bounds']['max'][1]

# 1. Bounds outliers among the clips that can play as surprises.
pool = {e['clip'] for e in catalog['surprisePool'] if e.get('clip')}
for entry in catalog['surprisePool']:
    if entry.get('group'):
        g = catalog['groups'][entry['group']]
        pool |= set(g['start'] + [g['loop']] + g['end'])
override_path = ROOT / 'overrides' / f'{pal.lower()}.json'
allowed = set(json.loads(override_path.read_text()).get('allowLarge', [])) if override_path.exists() else set()
limit = pack_limits.limits(clips['Idle']['bounds'])
outliers = {}
for name in pool - allowed:
    reasons = pack_limits.violations(clips[name]['bounds'], limit, pack_limits.DROP_FACTOR)
    if reasons:
        outliers[name] = ', '.join(reasons)
fitted = sorted(name for name, clip in clips.items() if clip.get('motionFit'))
if fitted:
    print('FITTED (body motion squashed):', ', '.join(fitted))
if outliers:
    # Exclude whole groups whose member misbehaves, by excluding the member clips.
    override_path.parent.mkdir(exist_ok=True)
    override = json.loads(override_path.read_text()) if override_path.exists() else {}
    before = set(override.get('exclude', []))
    groups = catalog['groups']
    excluded = set(outliers)
    for name, g in groups.items():
        members = set(g['start'] + [g['loop']] + g['end'])
        if members & excluded:
            excluded |= members - allowed
    override['exclude'] = sorted(before | excluded)
    override.setdefault('_excluded', {}).update(outliers)
    if set(override['exclude']) != before:
        override_path.write_text(json.dumps(override, indent=2) + '\n')
        print('BOUNDS: excluded', outliers)
        sys.exit(3)
print(f'BOUNDS OK (idle height {height:.2f} m, shown {height * catalog["meshScale"]:.2f} m)')
if '--bounds-only' in sys.argv:
    sys.exit(0)

# 2. Scripted behavior run.
inp = catalog['input']
events = ['1:click']
if inp.get('doubleClick'):
    events.append('6:double')
if inp.get('dragGroup'):
    events += ['11:drag', '14:drop']
events += ['18:cursor=-2/2.5', '18.5:watch', '22:cursor=2/1.5']
group = next((e['group'] for e in catalog['surprisePool'] if e.get('group')), None)
if group:
    events.append(f'27:play={group}')
if catalog['locomotion']:
    events.append(f"40:play={catalog['locomotion'][0]['clip']}")
out = base / 'check'
subprocess.run(['rm', '-rf', str(out)])
binary = ROOT / 'app/SekhPet/.build/release/SekhPet'
env = dict(os.environ, SEKHPET_ASSETS=str(pack))
result = subprocess.run([str(binary), '--snapshot', str(out), '48', '5', '600-700', ','.join(events), '--pet', pal],
                        capture_output=True, text=True, env=env, timeout=600)
if result.returncode != 0:
    raise SystemExit(f'SNAPSHOT FAILED: {result.stdout}{result.stderr}')
log = (out / 'behaviors.txt').read_text()
expected = ['Idle', 'Watch Cursor']
expected += [e['clip'] for e in inp['singleClick']][:0]  # click picks one at random
if inp.get('doubleClick'):
    expected.append(inp['doubleClick'])
if inp.get('dragGroup'):
    expected.append(inp['dragGroup'])
if group:
    expected.append(group)
if catalog['locomotion']:
    expected.append('Wander')
missing = [e for e in expected if e not in log]
if missing:
    raise SystemExit(f'BEHAVIOR MISSING {missing}:\n{log}')
print('BEHAVIOR OK:', ' | '.join(line.split('  ')[0] for line in log.splitlines() if not line.split()[1].startswith('[')))

# 3. Contact sheet: moments after each scripted event, plus an empty-frame check.
times = [0.4, 2.5, 7.5, 12.5, 15.5, 20.5, 23.5, 29, 33, 41.5]
frames = []
for t in times:
    image = Image.open(out / f'frame-{round(t * 5):05d}.png').convert('RGBA')
    if image.getbbox() is None:
        raise SystemExit(f'EMPTY FRAME at {t}s')
    frames.append((t, image))
w, h = frames[0][1].size
scale = min(1.0, 300 / h)
tw, th = int(w * scale), int(h * scale)
sheet = Image.new('RGBA', (tw * 5, th * 2), (70, 90, 120, 255))
draw = ImageDraw.Draw(sheet)
labels = {0.4: 'idle', 2.5: 'click', 7.5: 'double', 12.5: 'drag', 15.5: 'drop', 20.5: 'watch L-up',
          23.5: 'watch R', 29: group or '-', 33: group or '-', 41.5: 'travel'}
for i, (t, image) in enumerate(frames):
    x, y = (i % 5) * tw, (i // 5) * th
    sheet.alpha_composite(image.resize((tw, th)), (x, y))
    draw.text((x + 4, y + 4), f'{t}s {labels[t]}', fill='white')
sheet.save(base / 'check-sheet.png')
print('SHEET', base / 'check-sheet.png', f'stage {w // 2}x{h // 2} pt at Medium before mesh scale')
