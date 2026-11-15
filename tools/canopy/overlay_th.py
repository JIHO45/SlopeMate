# 나무 높이 지도(회색조: 0m 흰색 → 25m 이상 진한 녹색) 위에 OSM 슬로프 중심선(난이도 색, 1.5px)·리프트(검은 점선)를 겹친 PNG
import json, math, struct, sys, zlib
base, osm, out = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(base + '.json')); w, h, px, X0, Y0 = m['width'], m['height'], m['pixel_m'], m['x0'], m['y0']
img = open(base + '.u8', 'rb').read()
R = 6378137.0
def pix(lat, lon):
    x = R * math.radians(lon); y = R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
    return (x - X0) / px, (Y0 - y) / px
rgb = bytearray(w * h * 3)
for i, v in enumerate(img):
    t = 1.0 if v >= int(sys.argv[4]) else 0.0
    rgb[3 * i:3 * i + 3] = bytes((int(250 - 215 * t), int(250 - 170 * t), int(250 - 205 * t)))
def dot(x, y, c, r):
    for yy in range(int(y - r), int(y + r) + 1):
        for xx in range(int(x - r), int(x + r) + 1):
            if 0 <= xx < w and 0 <= yy < h and (xx - x) ** 2 + (yy - y) ** 2 <= r * r: rgb[3 * (yy * w + xx):3 * (yy * w + xx) + 3] = c
def line(pts, c, r, dash=None):
    run = 0.0
    for (a, b), (cc, d) in zip(pts, pts[1:]):
        n = max(1, int(math.hypot(cc - a, d - b) * 2))
        for k in range(n + 1):
            run += math.hypot(cc - a, d - b) / n / 2 if k else 0
            if dash and (run % (2 * dash)) > dash: continue
            dot(a + (cc - a) * k / n, b + (d - b) * k / n, c, r)
COL = {'novice': (40, 170, 70), 'easy': (40, 170, 70), 'intermediate': (40, 90, 220), 'advanced': (220, 40, 40), 'expert': (20, 20, 20), 'freeride': (230, 140, 0)}
d = json.load(open(osm))
for l in d['lifts']: line([pix(*p) for p in l['line']], bytes((0, 0, 0)), 0.9, dash=8)
for s in d['slopes']:
    for ln in s['lines']: line([pix(*p) for p in ln], bytes(COL.get(s.get('difficulty'), (230, 0, 200))), 1.2)
rows = b''.join(b'\0' + bytes(rgb[3 * y * w:3 * (y + 1) * w]) for y in range(h))
def chunk(tg, dt): return struct.pack('>I', len(dt)) + tg + dt + struct.pack('>I', zlib.crc32(tg + dt))
open(out, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 6)) + chunk(b'IEND', b''))
print(out, w, h)
