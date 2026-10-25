"""Give every clip's animation samples at its first and last frame.

  Blender --background --python pipeline/pad_clips.py -- work/<name>/realtime/clips/*.usdz

Blender's USD export writes only the samples where a value changes, and SceneKit plays
each track over its own samples' span: a clip whose only change is a blink 1.3 s in got
two samples a frame apart, and SceneKit looped that one frame's blend over and over (the
pet pulsing in size). Holding each track's first and last values at the clip's ends makes
the span the whole clip. Frame changes are made instant too.
"""
import shutil
import sys
import tempfile
from pathlib import Path

from pxr import Sdf, Usd, UsdSkel, UsdUtils

for path in map(Path, sys.argv[sys.argv.index('--') + 1:]):
    work = Path(tempfile.mkdtemp())
    stage = Usd.Stage.Open(str(path))
    flat = stage.Flatten()
    start, end = stage.GetStartTimeCode(), stage.GetEndTimeCode()
    padded = Usd.Stage.Open(flat)
    for prim in padded.Traverse():
        if not prim.IsA(UsdSkel.Animation):
            continue
        anim = UsdSkel.Animation(prim)
        for attr in (anim.GetTranslationsAttr(), anim.GetRotationsAttr(), anim.GetScalesAttr()):
            times = attr.GetTimeSamples()
            if not times:
                continue
            samples = [(t, attr.Get(t)) for t in times]
            # A change between neighbouring frames blends across that frame (both cards
            # half-shown): hold the old value until just before the new one instead.
            snapped = [(b - 0.001 if b - a <= 1 and nb != va and (i == 0 or va == samples[i - 1][1]) else a, va)
                       for i, ((a, va), (b, nb)) in enumerate(zip(samples, samples[1:]))] + samples[-1:]
            if snapped[0][0] > start:
                snapped.insert(0, (start, snapped[0][1]))
            if snapped[-1][0] < end:
                snapped.append((end, snapped[-1][1]))
            attr.Clear()
            for t, value in snapped:
                attr.Set(value, Usd.TimeCode(t))
    layer = work / (path.stem + '.usdc')
    padded.GetRootLayer().Export(str(layer))
    out = work / path.name
    UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(layer)), str(out))
    shutil.move(str(out), path)
    shutil.rmtree(work)
print('PAD_OK')
