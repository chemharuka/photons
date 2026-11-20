#!/usr/bin/env python3
"""Independent check of a `--dual-raw` DNG against its source.

Deliberately not Swift and not the tool's own reader: a bug in `SourceDNGDecode` that both sides
share would cancel out of a Swift-only comparison. This walks the IFDs itself and decodes the SOF3
tiles itself, so every number below is measured from the bytes on disk.

    python3 dng-dual-raw-check.py SRC.dng OUT.dng

What it asserts for a dual file:

  1. IFD0 is the preview page (`262 = 2`, `254 = 1`) and the IFD chain ends there — the raws are
     SubIFDs, not pages of the chain;
  2. `330 SubIFDs` holds exactly two entries, both CFA (`262 = 32803`) / lossless JPEG (`259 = 7`)
     at the source's geometry, the original at `[0]` (`NewSubfileType = 0`) and the denoised copy at
     `[1]` (`NewSubfileType = 0`, sample-descriptive tags only);
  3. `SubIFDs[0]` decodes to the *source mosaic* with a maximum absolute difference of 0;
  4. `SubIFDs[1]` decodes to something different from the source, with the rms difference reported.

`SubIFDs[0]` is what ImageIO/CIRAWFilter show: they take the first `NewSubfileType = 0` raw in that
array, and there is exactly one. `dng-promote-subifd --subifd 1` shows the other layer by promoting
it (which also sets its `254` to 0), and that is the check the Swift side cannot make.

A single-raw output (no `--dual-raw`) is accepted too: it must have no `330`, and rule 3 then applies
to its only page with the opposite sign — it must *differ* from the source, because IFD0 is the
denoised image there. That is the regression check.

Exit status 0 means every invariant matched.
"""
import array
import struct
import sys

COMP = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}


class TIFF:
    def __init__(self, path):
        self.path = path
        self.data = open(path, 'rb').read()
        d = self.data
        if d[0:2] != b'II' or struct.unpack('<H', d[2:4])[0] != 42:
            raise SystemExit(f'{path}: not a little-endian TIFF')
        self.ifd0_offset = struct.unpack('<I', d[4:8])[0]
        self.ifd0 = self.ifd(self.ifd0_offset)

    def ifd(self, off):
        d = self.data
        n = struct.unpack('<H', d[off:off + 2])[0]
        out = {}
        for i in range(n):
            b = off + 2 + 12 * i
            tag, typ, cnt = struct.unpack('<HHI', d[b:b + 8])
            sz = COMP.get(typ, 1) * cnt
            val = d[b + 8:b + 8 + sz] if sz <= 4 else d[struct.unpack('<I', d[b + 8:b + 12])[0]:][:sz]
            out[tag] = (typ, cnt, val)
        nxt = struct.unpack('<I', d[off + 2 + 12 * n:off + 6 + 12 * n])[0]
        return out, nxt

    def num(self, entries, tag):
        e = entries.get(tag)
        if e is None:
            return []
        typ, cnt, val = e
        if typ == 1:
            return list(val[:cnt])
        if typ == 3:
            return list(struct.unpack(f'<{cnt}H', val[:2 * cnt]))
        if typ == 4:
            return list(struct.unpack(f'<{cnt}I', val[:4 * cnt]))
        if typ in (5, 10):
            out = []
            for i in range(cnt):
                a, b = struct.unpack('<II', val[i * 8:i * 8 + 8])
                out.append(a / b if b else 0.0)
            return out
        return []

    def scalar(self, entries, tag, default=None):
        v = self.num(entries, tag)
        return v[0] if v else default

    def mosaic(self, entries):
        """Decodes one IFD's pixels: tiles (compression 1/7) or strips (compression 1)."""
        w = self.scalar(entries, 256)
        h = self.scalar(entries, 257)
        comp = self.scalar(entries, 259)
        samples = array.array('H', bytes(2 * w * h))
        if 322 in entries and 324 in entries:
            tw = self.scalar(entries, 322)
            th = self.scalar(entries, 323)
            offs = self.num(entries, 324)
            cnts = self.num(entries, 325)
            nx = (w + tw - 1) // tw
            ny = (h + th - 1) // th
            idx = 0
            for ty in range(ny):
                for tx in range(nx):
                    blob = self.data[offs[idx]:offs[idx] + cnts[idx]]
                    if comp == 1:
                        px = array.array('H')
                        px.frombytes(blob[:2 * tw * th])
                    elif comp == 7:
                        px = decode_sof3(blob, tw, th)
                    else:
                        raise SystemExit(f'unsupported compression {comp}')
                    for y in range(th):
                        dy = ty * th + y
                        if dy >= h:
                            break
                        cw = min(tw, w - tx * tw)
                        base = dy * w + tx * tw
                        samples[base:base + cw] = px[y * tw:y * tw + cw]
                    idx += 1
            return samples, w, h
        if 273 in entries:
            if comp != 1:
                raise SystemExit(f'strip + compression {comp} unsupported')
            offs = self.num(entries, 273)
            cnts = self.num(entries, 279)
            cur = 0
            for o, c in zip(offs, cnts):
                rows = c // 2 // w
                for r in range(rows):
                    if cur >= h:
                        break
                    base = o + r * w * 2
                    samples[cur * w:(cur + 1) * w] = array.array('H', self.data[base:base + 2 * w])
                    cur += 1
            return samples, w, h
        raise SystemExit('no tile or strip geometry')


def decode_sof3(data, expect_w, expect_h):
    """Lossless-JPEG (SOF3) decoder, written from the spec rather than mirrored from the encoder."""
    i = 2
    precision, comps, cw, h, pred = 16, 1, expect_w, expect_h, 1
    tables, sos = [], 0
    while i < len(data) - 1:
        if data[i] != 0xFF:
            i += 1
            continue
        m = data[i + 1]
        if m == 0xD8:
            i += 2
            continue
        if i + 4 > len(data):
            break
        ln = (data[i + 2] << 8) | data[i + 3]
        body = i + 4
        if m == 0xC3:
            precision = data[body]
            h = (data[body + 1] << 8) | data[body + 2]
            cw = (data[body + 3] << 8) | data[body + 4]
            comps = data[body + 5]
        elif m == 0xC4:
            p = body
            while p < i + 2 + ln:
                is_dc = (data[p] & 0xF0) == 0
                tid = data[p] & 0x0F
                counts = list(data[p + 1:p + 17])
                total = sum(counts)
                syms = list(data[p + 17:p + 17 + total])
                p += 17 + total
                if not is_dc:
                    continue
                code, si, entries = 0, 0, {}
                for l in range(1, 17):
                    for _ in range(counts[l - 1]):
                        entries[(l, code)] = syms[si]
                        si += 1
                        code += 1
                    code <<= 1
                while len(tables) <= tid:
                    tables.append({})
                tables[tid] = entries
        elif m == 0xDA:
            p = body
            ns = data[p]
            p += 1
            sel = []
            for _ in range(ns):
                p += 1
                sel.append(data[p] >> 4)
                p += 1
            pred = data[p]
            sos = i + 2 + ln
            tables = [(tables[s] if s < len(tables) else {}) for s in sel] if sel else tables
        else:
            pass
        if m == 0xDA:
            break
        i += 2 + ln

    acc, nbits, pos = 0, 0, sos
    mask = (1 << precision) - 1
    half = 1 << (precision - 1)

    def bit():
        nonlocal acc, nbits, pos
        while nbits == 0:
            b = data[pos]
            pos += 1
            if b == 0xFF:
                pos += 1
            acc, nbits = b, 8
        nbits -= 1
        return (acc >> nbits) & 1

    out = array.array('H', bytes(2 * cw * comps * h))
    for y in range(h):
        row = y * comps * cw
        for x in range(cw):
            for c in range(comps):
                tbl = tables[c] if c < len(tables) else {}
                cat, code = 0, 0
                found = False
                for l in range(1, 17):
                    code = (code << 1) | bit()
                    if (l, code) in tbl:
                        cat = tbl[(l, code)]
                        found = True
                        break
                if not found:
                    raise SystemExit('corrupt SOF3 stream')
                d = 0
                if cat > 0:
                    v = 0
                    for _ in range(cat):
                        v = (v << 1) | bit()
                    d = v if v >= (1 << (cat - 1)) else v - (1 << cat) + 1
                here = row + x * comps + c
                if pred == 1:
                    if x > 0:
                        pv = out[here - comps]
                    elif y > 0:
                        pv = out[here - comps * cw]
                    else:
                        pv = half
                else:
                    pv = out[here - comps * cw] if y > 0 else half
                out[here] = (pv + d) & mask
    return out


def diff_stats(a, b):
    worst, total, n = 0, 0.0, min(len(a), len(b))
    for i in range(n):
        d = int(a[i]) - int(b[i])
        worst = max(worst, abs(d))
        total += d * d
    return worst, (total / max(n, 1)) ** 0.5


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, out = TIFF(sys.argv[1]), TIFF(sys.argv[2])
    ok = True

    def check(name, a, b):
        nonlocal ok
        good = a == b
        ok = ok and good
        print(f'  {"PASS" if good else "FAIL"}  {name:<22} {a}  vs  {b}')

    print(f'source : {sys.argv[1]}')
    print(f'output : {sys.argv[2]}')

    src_ifd0, _ = src.ifd0
    out_ifd0, out_next = out.ifd0
    # The source's raw may be IFD0 (a camera DNG) or the first SubIFD.
    if src.scalar(src_ifd0, 262) == 32803:
        src_raw = src_ifd0
    elif 330 in src_ifd0:
        src_raw = src.ifd(src.scalar(src_ifd0, 330))[0]
    else:
        raise SystemExit(f'{sys.argv[1]}: no CFA image')

    print('\nIFD0')
    sub = out.num(out_ifd0, 330)
    if not sub:
        # Single-raw file: the pre-existing layout, IFD0 = the raw, IFD1 = the preview.
        print('  info  no 330 — single-raw file (expected without --dual-raw)')
        check('photometric', 32803, out.scalar(out_ifd0, 262))
        check('compression', 7, out.scalar(out_ifd0, 259))
        check('newSubfileType', 0, out.scalar(out_ifd0, 254))
        check('width', src.scalar(src_raw, 256), out.scalar(out_ifd0, 256))
        check('height', src.scalar(src_raw, 257), out.scalar(out_ifd0, 257))
        check('bitsPerSample', 16, out.scalar(out_ifd0, 258))
        alternate = None
        print('\nIFD1 (the preview)')
        check('ifdChainHasNext', True, out_next != 0)
        if out_next:
            prev_ifd, _ = out.ifd(out_next)
            check('previewPhotometric', True, out.scalar(prev_ifd, 262) in (2, 6))
            check('previewHasStrips', True, 273 in prev_ifd)
    else:
        # Dual file: IFD0 is the preview, the raws live in SubIFDs, original first.
        check('photometric', 2, out.scalar(out_ifd0, 262))
        check('newSubfileType', 1, out.scalar(out_ifd0, 254))
        check('hasStrips', True, 273 in out_ifd0)
        check('ifdChainEnds', 0, out_next)

        print('\nSubIFDs')
        check('subIFDCount', 2, len(sub))
        original_ifd, _ = out.ifd(sub[0])
        alternate = out.ifd(sub[1])[0]
        check('subIFD0.newSubfileType', 0, out.scalar(original_ifd, 254))
        check('subIFD1.newSubfileType', 0, out.scalar(alternate, 254))
        for name, page in (('subIFD0', original_ifd), ('subIFD1', alternate)):
            check(f'{name}.photometric', 32803, out.scalar(page, 262))
            check(f'{name}.compression', 7, out.scalar(page, 259))
            check(f'{name}.width', src.scalar(src_raw, 256), out.scalar(page, 256))
            check(f'{name}.height', src.scalar(src_raw, 257), out.scalar(page, 257))
            # CFA pattern has to be on the page itself: IFD0 is a preview and cannot supply it.
            check(f'{name}.cfaRepeatPatternDim', src.num(src_raw, 33421), out.num(page, 33421))
            check(f'{name}.cfaPattern', src.num(src_raw, 33422), out.num(page, 33422))
        for tag in (330, 34665, 34853, 700):
            check(f'subIFD1.no.tag{tag}', False, tag in alternate)
        if 270 in alternate:
            print('  info  subIFD1 ImageDescription: '
                  + alternate[270][2].rstrip(b'\x00').decode('ascii', 'replace'))
        out_ifd0 = original_ifd        # the page a decoder resolves "the picture" to

    print('\npixels')
    src_samples, sw, sh = src.mosaic(src_raw)
    out0, w0, h0 = out.mosaic(out_ifd0)
    check('geometry', (sw, sh), (w0, h0))
    worst, rms = diff_stats(src_samples, out0)
    if alternate is None:
        # Single-raw output: IFD0 *is* the denoised result, so the invariant is the opposite one —
        # it must differ from the source, and this is the file the pre-`--dual-raw` tool wrote.
        print(f'  info  IFD0 vs source: max|diff| {worst}, rms {rms:.2f} (denoised, as expected)')
        good = rms > 0
        ok = ok and good
        print(f'  {"PASS" if good else "FAIL"}  IFD0 carries the denoised pixels')
    else:
        check('SubIFDs[0] vs source max|diff|', 0, worst)
        print(f'  info  SubIFDs[0] vs source rms {rms:.4f}')
    if alternate is not None:
        alt, wa, ha = out.mosaic(alternate)
        check('alternate geometry', (sw, sh), (wa, ha))
        worst_alt, rms_alt = diff_stats(src_samples, alt)
        print(f'  info  alternate vs source: max|diff| {worst_alt}, rms {rms_alt:.2f}')
        print(f'  info  alternate vs IFD0  : max|diff| {diff_stats(out0, alt)[0]}, '
              f'rms {diff_stats(out0, alt)[1]:.2f}')
        differs = sum(1 for a, b in zip(src_samples, alt) if a != b)
        print(f'  info  samples differing from the source: {differs}/{sw * sh} '
              f'({100.0 * differs / (sw * sh):.1f} %)')
        good = rms_alt > 0
        ok = ok and good
        print(f'  {"PASS" if good else "FAIL"}  alternate differs from source')

    print('\nRESULT:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
