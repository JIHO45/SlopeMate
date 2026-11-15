import json, math, struct, sys, zlib
sys.path.insert(0, sys.argv[1]); from cog import ifds, rng
url, osm, out = sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(osm))
pts = [p for s in d['slopes'] for l in s['lines'] for p in l] + [p for l in d['lifts'] for p in l['line']]
lat0, lat1 = min(p[0] for p in pts), max(p[0] for p in pts); lon0, lon1 = min(p[1] for p in pts), max(p[1] for p in pts)
pad = 800 / 111320  # 800 m
lat0 -= pad; lat1 += pad; lon0 -= pad / math.cos(math.radians(lat0)); lon1 += pad / math.cos(math.radians(lat0))
R = 6378137.0
def merc(lat, lon): return R * math.radians(lon), R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
HALF = math.pi * R; TS = 2 * HALF / 1024; N = 32768; px = TS / N   # zoom 10 타일 한 장 = 32768 px
xa, ya = merc(lat1, lon0); xb, yb = merc(lat0, lon1)
gc0, gr0 = int((xa + HALF) / px), int((HALF - ya) / px); gc1, gr1 = int((xb + HALF) / px) + 1, int((HALF - yb) / px) + 1
w, h = gc1 - gc0, gr1 - gr0; img = bytearray(w * h)
def qk(tx, ty):
    return ''.join(str((1 if tx >> i & 1 else 0) + (2 if ty >> i & 1 else 0)) for i in range(9, -1, -1))
for Ty in range(gr0 // N, (gr1 - 1) // N + 1):
    for Tx in range(gc0 // N, (gc1 - 1) // N + 1):
        u = url.format(qk(Tx, Ty)); t = ifds(u)[0]; TW = t[322][0]; nt = N // TW; offs, cnts = t[324], t[325]
        assert t[256][0] == N and abs(t[33922][3] - (Tx * TS - HALF)) < 1, u
        c0, r0 = max(gc0, Tx * N) - Tx * N, max(gr0, Ty * N) - Ty * N
        c1, r1 = min(gc1, Tx * N + N) - Tx * N, min(gr1, Ty * N + N) - Ty * N
        for ty in range(r0 // TW, (r1 - 1) // TW + 1):
            for tx in range(c0 // TW, (c1 - 1) // TW + 1):
                k = ty * nt + tx
                raw = zlib.decompress(rng(u, offs[k], cnts[k])) if cnts[k] else bytes(TW * TW)
                for y in range(TW):
                    ly = ty * TW + y
                    if not r0 <= ly < r1: continue
                    xs, xe = max(c0, tx * TW), min(c1, tx * TW + TW)
                    o = (Ty * N + ly - gr0) * w + Tx * N + xs - gc0
                    img[o:o + xe - xs] = raw[y * TW + xs - tx * TW:y * TW + xe - tx * TW]
X0, Y0, c0, r0 = -HALF, HALF, gc0, gr0
open(out + '.u8', 'wb').write(img)
json.dump({'width': w, 'height': h, 'pixel_m': px, 'x0': X0 + c0 * px, 'y0': Y0 - r0 * px, 'crs': 'EPSG:3857',
           'source': 'Meta/WRI CHM v2 (CC BY 4.0), via source.coop tge-labs/meta-chm-v2'}, open(out + '.json', 'w'), indent=1)
# 미리보기 PNG(높이 0~30m → 밝기)
rows = b''.join(b'\0' + bytes(min(255, v * 8) for v in img[y * w:(y + 1) * w]) for y in range(h))
def chunk(tg, dt): return struct.pack('>I', len(dt)) + tg + dt + struct.pack('>I', zlib.crc32(tg + dt))
open(out + '.png', 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 6)) + chunk(b'IEND', b''))
print(w, h, sum(1 for v in img if v >= 3) / len(img))
