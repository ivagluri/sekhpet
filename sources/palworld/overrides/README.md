# Per-pal overrides

Optional hand fixes, one file per pal: `sources/palworld/overrides/<pal lowercased>.json`. `sources/palworld/make_pal_config.py` merges it over the generated config: dicts merge, lists replace, and `exclude` accumulates. The bounds check also records clips it had to drop here, under `exclude` and `_excluded`.

```json
{
  "displayName": "Bellanoir Libero",
  "exclude": ["Swim_Idle"],
  "allowLarge": ["TrickShow_01"],
  "input": {"doubleClick": "Skill_Special"}
}
```

Common keys: `displayName`, `exclude` (clips never played), `allowLarge` (keep clips the bounds check would drop), `input` (click, double-click and drag reactions), `groups`, `clips.<name>.facing`, `feet` (bones for stride measurement). See [PIPELINE.md](../../../PIPELINE.md).
