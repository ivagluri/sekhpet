"""Size limits for a pal's clips, shared by the exporter and the bounds check.

A clip that rises, sinks or sweeps past these (relative to the idle pose) has the
excess body motion squashed by export_realtime.py. Whatever is left comes from the
pose itself and is kept, at the cost of a bigger window. check_pack.py drops a clip
only if it still exceeds the limits by DROP_FACTOR after that.
"""

RISE = 1.6    # top of the clip, in idle heights
SINK = 0.35   # depth below the floor, in idle heights
SWEEP = 1.25  # horizontal reach from centre, in idle heights...
SWEEP_OVER_IDLE = 1.2  # ...or this many times the idle reach, for long-bodied pals
DROP_FACTOR = 1.6
# Rises and sweeps only a little past the limit are a pose (rearing up, spread wings),
# not travel: they're left alone unless more than this far over. Sinks are always fitted.
FIT_MARGIN = 1.1


def limits(idle_bounds):
    """Limits in model metres, from the idle clip's bounds."""
    height = idle_bounds['max'][1]
    return {'top': RISE * height, 'bottom': -SINK * height,
            'radius': max(SWEEP * height, SWEEP_OVER_IDLE * idle_bounds['horizontalRadius'])}


def needs_fit(bounds, limit):
    """Whether the exporter should squash this clip's motion."""
    return (bounds['min'][1] < limit['bottom'] or bounds['max'][1] > limit['top'] * FIT_MARGIN
            or bounds['horizontalRadius'] > limit['radius'] * FIT_MARGIN)


def violations(bounds, limit, factor=1.0):
    """How `bounds` exceeds `limit` (scaled by `factor`), as readable reasons."""
    reasons = []
    if bounds['min'][1] < limit['bottom'] * factor:
        reasons.append(f"sinks {bounds['min'][1]:.2f} m")
    if bounds['max'][1] > limit['top'] * factor:
        reasons.append(f"rises to {bounds['max'][1]:.2f} m")
    if bounds['horizontalRadius'] > limit['radius'] * factor:
        reasons.append(f"sweeps {bounds['horizontalRadius']:.2f} m")
    return reasons
