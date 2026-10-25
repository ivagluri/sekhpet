"""Apply the single macOS output-path compatibility fix to pinned CUE4Parse."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
path = root / '.tools/CUE4Parse/CUE4Parse-Conversion/ExportSession.cs'
source = path.read_text(encoding='utf-8-sig')
old = "return fullPath.Replace('/', '\\\\');"
new = 'return fullPath;'
if old in source:
    path.write_text(source.replace(old, new))
elif new not in source:
    raise SystemExit('Upstream output-path code changed; review before patching.')
print('Native output-path compatibility fix is applied.')

# Per-track compressed additive clips need zero scale deltas when no scale
# track exists. An absolute scale of one compounds through the hierarchy.
path = root / '.tools/CUE4Parse/CUE4Parse-Conversion/Legacy/AnimConverter.cs'
source = path.read_text(encoding='utf-8-sig')
old = 'track.KeyScale = [FVector.OneVector];'
new = 'track.KeyScale = [animSequence.IsValidAdditive() ? FVector.ZeroVector : FVector.OneVector];'
if old in source:
    assert source.count(old) == 1
    path.write_text(source.replace(old, new))
elif new not in source:
    raise SystemExit('Upstream scale fallback changed; review before patching.')
print('Additive missing-scale fallback fix is applied.')
