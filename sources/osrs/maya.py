"""Skeletal ("animaya") NPCs: newer OSRS content animates real bones with keyframe curves (index 22) instead
of vertex labels. The decoder is a port of Qodat's (GPL-3), so it lives in maya_local.py, kept out of git;
without it, these NPCs can't be built."""
from cache import Buf


def skeleton_of(cache, maya_id, _memo={}):
    """The skeleton (framemap) an animaya animation is made for, from its header. A sequence's animaya id
    packs the index 22 archive and file as archive << 16 | file."""
    if maya_id not in _memo:
        files = cache.files(22, maya_id >> 16)
        data = files.get(maya_id & 0xFFFF)
        _memo[maya_id] = None if data is None else Buf(data, 1).u16()
    return _memo[maya_id]


def build(*args, **kw):
    try:
        import maya_local
    except ImportError:
        raise SystemExit("This NPC uses skeletal (animaya) animations, which need sources/osrs/maya_local.py: "
                         "a local-only port of Qodat's decoder (see sources/osrs/README.md).")
    return maya_local.build(*args, **kw)
