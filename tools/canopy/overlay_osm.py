# 나무 높이 지도(2배 축소) 위에 OSM 건물(빨강)·주차장(노랑)·골프(파랑)·주거지(보라)·도로(회색)·슬로프(검정) 윤곽
import json, math, struct, sys, zlib
base, osmx, slopes, out = sys.argv[1:5]
m = json.load(open(base + '.json')); W, H, px, X0, Y0 = m['width'], m['height'], m['pixel_m'], m['x0'], m['y0']
img = open(base + '.u8', 'rb').read(); k = 2; w, h = W // k, H // k
R = 6378137.0
def pix(lat, lon):
    x = R * math.radians(lon); y = R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
    return (x - X0) / px / k, (Y0 - y) / px / k
rgb = bytearray(w * h * 3)
for yy in range(h):
    row = img[yy * k * W: yy * k * W + W]
    for xx in range(w):
        t = min(row[xx * k], 25) / 25
        o = (yy * w + xx) * 3; rgb[o:o + 3] = bytes((int(255 - t * 205), int(255 - t * 160), int(255 - t * 205)))
def dot(x, y, c, r):
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            X, Y = int(x) + dx, int(y) + dy
            if 0 <= X < w and 0 <= Y < h: o = (Y * w + X) * 3; rgb[o:o + 3] = bytes(c)
def line(pts, c, r):
    for (a, b), (cc, d) in zip(pts, pts[1:]):
        x1, y1 = pix(a, b); x2, y2 = pix(cc, d); n = int(max(abs(x2 - x1), abs(y2 - y1))) + 1
        for i in range(n + 1): dot(x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n, c, r)
d = json.load(open(osmx))
for e in d['elements']:
    t = e.get('tags', {})
    geoms = [e['geometry']] if 'geometry' in e else [mm['geometry'] for mm in e.get('members', []) if 'geometry' in mm]
    if 'building' in t: c, r = (230, 30, 30), 1
    elif t.get('amenity') == 'parking': c, r = (240, 190, 0), 1
    elif 'golf' in t or t.get('leisure') == 'golf_course': c, r = (30, 90, 230), 1
    elif t.get('landuse') == 'residential': c, r = (150, 60, 200), 1
    elif 'highway' in t: c, r = (120, 120, 120), 0
    else: continue
    for g in geoms: line([(p['lat'], p['lon']) for p in g], c, r)
for s in json.load(open(slopes))['slopes']:
    for l in s['lines']: line(l, (0, 0, 0), 0)
def chunk(tg, dt): return struct.pack('>I', len(dt)) + tg + dt + struct.pack('>I', zlib.crc32(tg + dt))
raw = b''.join(b'\0' + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))
open(out, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
