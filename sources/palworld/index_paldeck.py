"""Index the paldeck from the decoded game tables: work/tables/paldeck.json, which the
config generator reads for display names. make_pet.sh runs it after decoding the tables.

  python3 sources/palworld/index_paldeck.py --print   # every pal: number, name, internal name, model

Reads work/tables/tables.json (DT_PalMonsterParameter and the English
DT_PalNameText_Common) and work/tables/paklist.txt (the archive listing).
"""
import json
import re
import sys
from pathlib import Path

TABLES = Path(__file__).resolve().parents[2] / 'work/tables'

data = json.loads((TABLES / 'tables.json').read_text())
names = next(v for k, v in data.items() if 'NameText' in k)[0]['Rows']
params = next(v for k, v in data.items() if 'MonsterParameter' in k)[0]['Rows']
paks = (TABLES / 'paklist.txt').read_text().splitlines()
models = {m.group(1) for p in paks if (m := re.match(r'Pal/Content/Pal/Model/Character/Monster/[^/]+/SK_([^/.]+)\.uasset$', p))}


def display(key, row):
    for text_id in (row.get('OverrideNameTextID'), f'PAL_NAME_{key}'):
        entry = names.get(text_id or '')
        if entry:
            return entry['TextData']['LocalizedString']
    return '?'


entries = {}
for key, row in params.items():
    if not row.get('IsPal') or row.get('ZukanIndex', -1) < 0:
        continue
    if key.upper().startswith(('BOSS_', 'RAID_', 'GYM_', 'PREDATOR_', 'SUMMON_', 'QUEST_')):
        continue
    suffix = row.get('ZukanIndexSuffix') or ''
    entry = (row['ZukanIndex'], suffix, display(key, row), key, key in models)
    # One row per paldeck entry: prefer the key with its own model, then the plainest key.
    previous = entries.get((entry[0], suffix))
    if previous is None or (entry[4], -len(key)) > (previous[4], -len(previous[3])):
        entries[(entry[0], suffix)] = entry

rows = sorted(entries.values())
(TABLES / 'paldeck.json').write_text(json.dumps(rows))
if '--print' in sys.argv:
    for index, suffix, name, key, model in rows:
        print(f"{index}{suffix:<2} {name:<24} {key:<26} {'' if model else '(no model folder of its own)'}")
else:
    print(f'indexed {len(rows)} pals')
