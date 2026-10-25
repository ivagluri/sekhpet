# Faster animated-mesh bounds

During the Aerith conversion on 2026-10-24, a local export wrapper replaced the Python vertex loop in `export_realtime.py::measure_bounds` with Blender's bulk vertex access and NumPy array operations. This is an implementation optimization of the existing calculation, not a new fitting rule or a reduction in sampling.

**Status:** adopted in `export_realtime.py::measure_bounds` after a second check on Tifa (Idle, Limit02, Attack01: zero difference, 22x faster). The scalar version below is kept for comparison.

## The calculation

For each sampled animation frame, the existing exporter evaluates the deformed mesh and visits every vertex. It computes a world-space point `q = M × p`, converts Blender coordinates to SceneKit as `(qx, qz, -qy)`, and accumulates the minimum, maximum and largest horizontal distance from the origin.

The bulk version performs exactly those operations on an array:

1. Copy all evaluated vertex coordinates with `vertices.foreach_get('co', buffer)`.
2. Apply the world matrix to all vertices with array multiplication.
3. Reduce each axis with `min`/`max`, and compute the maximum `hypot(qx, qy)`.
4. Reorder and negate the reduced axes to SceneKit coordinates.

It retains the same `use_action`, dependency-graph evaluation, `BOUNDS_STEP` (currently 3), final-frame sample, world transform, origin-based radius and rounding to four decimal places. It does not use the undeformed mesh or a bounding-box approximation, drop vertices, or skip more animation frames. USD export, textures, animation timing and fitting limits are unchanged.

## Candidate replacement

This function uses the same module globals and helper functions as the existing `measure_bounds`. NumPy is included in the tested Blender 5.2.2 distribution; it runs inside Blender's Python. A production integration can import NumPy once at module scope.

```python
def measure_bounds(action):
    import numpy as np

    use_action(action)
    low = np.full(3, math.inf)
    high = np.full(3, -math.inf)
    radius = 0.0
    frames = list(range(1, last_frame(action) + 1, BOUNDS_STEP)) + [last_frame(action)]

    for frame in frames:
        scene.frame_set(frame)
        evaluated = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
        points = np.empty(len(evaluated.data.vertices) * 3, dtype=np.float32)
        evaluated.data.vertices.foreach_get('co', points)
        matrix = np.asarray(evaluated.matrix_world, dtype=np.float32)
        world = points.reshape(-1, 3) @ matrix[:3, :3].T + matrix[:3, 3]

        low = np.minimum(low, world.min(axis=0))
        high = np.maximum(high, world.max(axis=0))
        radius = max(radius, float(np.hypot(
            world[:, 0].astype(np.float64),
            world[:, 1].astype(np.float64),
        ).max()))

    # Blender (x, y, z) -> SceneKit (x, z, -y).
    # Negating an axis exchanges its minimum and maximum.
    lo = [float(low[0]), float(low[2]), float(-high[1])]
    hi = [float(high[0]), float(high[2]), float(-low[1])]
    return {
        'min': [round(value, 4) for value in lo],
        'max': [round(value, 4) for value in hi],
        'horizontalRadius': round(radius, 4),
    }
```

Coordinates and matrix multiplication use `float32`, matching Blender's vertex and transform storage. Radius calculations use `float64` to track the existing Python `math.hypot` calculation closely. Temporary coordinate arrays cost memory proportional to the number of vertices, rather than to the length of the animation; they are replaced per frame.

## Validation and timing

The original Aerith export compared both implementations on Idle, Attack01 and Limit02 before each of two complete exports. Both comparisons reported zero difference in every returned bound, after the exporter's four-decimal rounding. The resulting pack passed the normal bounds/behavior checks, visual review and eleven individual battle-playback checks.

A separate read-only benchmark then compared all seven returned numbers (three minima, three maxima, radius) across all four source routes. It also repeated Idle under a world transform combining translation, rotation, nonuniform scale and reflection for each character. The benchmark loaded the existing Blender files without exporting or installing any packs.

All **13 clip comparisons** and **four transformed-Idle comparisons** had **zero difference in the returned, rounded bounds**. No packs were changed by these benchmarks.

| Character | Clip | Vertices | Sampled frames | Original (s) | Bulk (s) | Original / bulk |
|---|---|---:|---:|---:|---:|---:|
| Lucca | Idle (cold) | 416 | 35 | 0.0313 | 0.0649 | 0.48× |
| Lucca | Walk | 416 | 11 | 0.0101 | 0.0032 | 3.16× |
| Lucca | Mallet | 416 | 9 | 0.0079 | 0.0024 | 3.32× |
| ElenaPSX | Idle (cold) | 654 | 13 | 0.0177 | 0.0340 | 0.52× |
| ElenaPSX | Run | 654 | 11 | 0.0144 | 0.0033 | 4.30× |
| ElenaPSX | Kick | 654 | 16 | 0.0201 | 0.0047 | 4.26× |
| MoonQueen | Idle (cold) | 10,188 | 44 | 0.7341 | 0.0905 | 8.11× |
| MoonQueen | Walk | 10,188 | 19 | 0.3168 | 0.0310 | 10.22× |
| MoonQueen | Encount | 10,188 | 17 | 0.2827 | 0.0235 | 12.04× |
| Aerith | Idle (cold) | 116,792 | 108 | 20.4249 | 0.9199 | 22.20× |
| Aerith | Attack01 | 116,792 | 24 | 4.3602 | 0.1951 | 22.35× |
| Aerith | Limit02 | 116,792 | 76 | 13.9815 | 0.6127 | 22.82× |
| Aerith | Rest01 | 116,792 | 248 | 47.1153 | 2.0006 | 23.55× |

“Cold” marks the first NumPy call in a fresh Blender process, including its import overhead.

The read-only benchmark and full JSON results remain in `work/pipeline-tests/benchmark_bounds.py` and `bounds-benchmark-<pet>.json` on the test machine. Those local files reference private generated character inputs and are not distributed with the repository.

These are single-pass wall-clock timings for **bounds measurement only**, on this Mac with Blender 5.2.2. They are not an end-to-end pipeline speedup or a universal performance guarantee. The first bulk call in each process includes the initial NumPy import cost; that can outweigh the savings on a very small mesh. Later calls reuse the imported module.

## Integration considerations

- Replace the shared function directly when adopting this implementation; do not promote the temporary source-rewriting wrapper into the regular pipeline.
- Keep the scalar implementation available to a separate validation/benchmark command. Time both implementations with `time.perf_counter()` on the same loaded action and compare all returned bounds.
- The recorded comparisons test returned values rounded to four decimals. They do not prove bit-for-bit equality of every intermediate vertex operation on every Blender/NumPy build. Array multiplication and `mathutils` can round differently, especially under extreme coordinates or transforms. The benchmark allowed up to 0.00011 m difference in returned values; observed differences are recorded above.
- Test clips close to the fitting/exclusion thresholds before broad adoption, since even small numeric differences can matter at an exact threshold.
- The function assumes a nonempty evaluated mesh, as the pet pipeline requires. A production integration should make an empty-mesh failure explicit.
- Other per-vertex loops, including `lowest_points`, are separate optimization opportunities and were not changed by this replacement.
