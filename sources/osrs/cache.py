"""Read-only reader for the OSRS disk cache RuneLite keeps (main_file_cache.dat2 + idxN).
OSRS_CACHE overrides where it is."""
import bz2, gzip, os, struct

CACHE = os.environ.get("OSRS_CACHE") or os.path.expanduser("~/.runelite/jagexcache/oldschool/LIVE")


class Buf:
    def __init__(self, b, pos=0):
        self.b = b; self.p = pos

    def rem(self): return len(self.b) - self.p
    def u8(self): v = self.b[self.p]; self.p += 1; return v
    def i8(self): v = self.u8(); return v - 256 if v > 127 else v
    def u16(self): v = (self.b[self.p] << 8) | self.b[self.p + 1]; self.p += 2; return v
    def i16(self): v = self.u16(); return v - 65536 if v > 32767 else v
    def u24(self): v = int.from_bytes(self.b[self.p:self.p + 3], "big"); self.p += 3; return v
    def i32(self): v = struct.unpack_from(">i", self.b, self.p)[0]; self.p += 4; return v
    def u32(self): v = struct.unpack_from(">I", self.b, self.p)[0]; self.p += 4; return v
    def peek(self): return self.b[self.p]

    def big_smart(self):
        return self.i32() & 0x7FFFFFFF if self.peek() >= 0x80 else self.u16()

    def big_smart2(self):  # -1 encoded as 32767
        if self.peek() >= 0x80:
            return self.i32() & 0x7FFFFFFF
        v = self.u16()
        return -1 if v == 32767 else v

    def short_smart(self):  # signed smart
        return self.u8() - 64 if self.peek() < 128 else self.u16() - 49152

    def u_smart(self):
        return self.u8() if self.peek() < 128 else self.u16() - 32768

    def string(self):
        e = self.b.index(0, self.p); s = self.b[self.p:e].decode("latin-1"); self.p = e + 1; return s


def decompress(c):
    kind = c[0]; clen = struct.unpack_from(">i", c, 1)[0]
    if kind == 0:
        return c[5:5 + clen]
    dlen = struct.unpack_from(">i", c, 5)[0]
    body = c[9:9 + clen]
    if kind == 1:
        out = bz2.decompress(b"BZh1" + body)
    elif kind == 2:
        out = gzip.decompress(body)
    else:
        raise ValueError(f"compression {kind}")
    assert len(out) == dlen
    return out


class Cache:
    def __init__(self, path=CACHE):
        self.dat = open(os.path.join(path, "main_file_cache.dat2"), "rb").read()
        self.path = path
        self._idx = {}; self._tables = {}

    def _raw(self, index, archive):
        if index not in self._idx:
            self._idx[index] = open(os.path.join(self.path, f"main_file_cache.idx{index}"), "rb").read()
        idx = self._idx[index]
        e = idx[archive * 6:archive * 6 + 6]
        if len(e) < 6:
            return None
        length = int.from_bytes(e[0:3], "big"); sector = int.from_bytes(e[3:6], "big")
        if length == 0 or sector == 0:
            return None
        out = bytearray(); chunk = 0; big = archive > 0xFFFF
        while len(out) < length:
            off = sector * 520
            if big:
                aid, ch, nxt, ix = struct.unpack_from(">IH", self.dat, off) + (int.from_bytes(self.dat[off + 6:off + 9], "big"), self.dat[off + 9])
                hdr = 10
            else:
                aid, ch = struct.unpack_from(">HH", self.dat, off)
                nxt = int.from_bytes(self.dat[off + 4:off + 7], "big"); ix = self.dat[off + 7]; hdr = 8
            assert aid == archive and ch == chunk and ix == index, (index, archive, aid, ch, ix)
            take = min(520 - hdr, length - len(out))
            out += self.dat[off + hdr:off + hdr + take]
            sector = nxt; chunk += 1
        return bytes(out)

    def table(self, index):
        """{archive_id: [file ids]} from the reference table in idx255."""
        if index in self._tables:
            return self._tables[index]
        b = Buf(decompress(self._raw(255, index)))
        proto = b.u8()
        if proto >= 6: b.i32()
        flags = b.u8(); named = flags & 1; sized = flags & 4
        rd = b.big_smart if proto >= 7 else b.u16
        n = rd(); ids = []; last = 0
        for _ in range(n):
            last += rd(); ids.append(last)
        if named: b.p += 4 * n
        b.p += 4 * n  # crc
        if sized: b.p += 8 * n
        b.p += 4 * n  # revision
        counts = [rd() for _ in range(n)]
        files = {}
        for a, c in zip(ids, counts):
            last = 0; fl = []
            for _ in range(c):
                last += rd(); fl.append(last)
            files[a] = fl
        self._tables[index] = files
        return files

    def archive(self, index, archive):
        raw = self._raw(index, archive)
        return None if raw is None else decompress(raw)

    def files(self, index, archive):
        """{file_id: bytes} for an archive (split into its files)."""
        ids = self.table(index).get(archive)
        data = self.archive(index, archive)
        if ids is None or data is None:
            return {}
        if len(ids) == 1:
            return {ids[0]: data}
        chunks = data[-1]; n = len(ids)
        tbl = Buf(data, len(data) - 1 - chunks * n * 4)
        sizes = [[0] * n for _ in range(chunks)]
        for c in range(chunks):
            s = 0
            for f in range(n):
                s += tbl.i32(); sizes[c][f] = s
        out = [bytearray() for _ in range(n)]; p = 0
        for c in range(chunks):
            for f in range(n):
                out[f] += data[p:p + sizes[c][f]]; p += sizes[c][f]
        return {fid: bytes(o) for fid, o in zip(ids, out)}
