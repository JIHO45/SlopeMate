# 나무 높이 지도와 같은 격자(EPSG:3857, 1.19m)에 OSM 건물=1, 도로=2, 주차장=3 (u8)
import json, math, sys
base, osmx, out = sys.argv[1:4]
m = json.load(open(base + '.json')); W, H, px, X0, Y0 = m['width'], m['height'], m['pixel_m'], m['x0'], m['y0']
R = 6378137.0
def pix(lat, lon):
    x = R * math.radians(lon); y = R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
    return (x - X0) / px, (Y0 - y) / px
g = bytearray(W * H)
def fill(poly, v):
    ys = [p[1] for p in poly]
    for y in range(max(0, int(min(ys))), min(H, int(max(ys)) + 1)):
        yc = y + 0.5; xs = []
        for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
            if (y1 <= yc) != (y2 <= yc): xs.append(x1 + (yc - y1) * (x2 - x1) / (y2 - y1))
        xs.sort()
        for a, b in zip(xs[::2], xs[1::2]):
            for x in range(max(0, int(a + 0.5)), min(W, int(b + 0.5))):
                if v != 3 or g[y * W + x] == 0: g[y * W + x] = v
def stroke(pts, v, half):
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        n = int(max(abs(x2 - x1), abs(y2 - y1))) + 1; r = int(half + 0.5)
        for i in range(n + 1):
            cx, cy = x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    X, Y = int(cx) + dx, int(cy) + dy
                    if dx * dx + dy * dy <= half * half and 0 <= X < W and 0 <= Y < H and g[Y * W + X] == 0: g[Y * W + X] = v
width = {'motorway': 10, 'trunk': 9, 'primary': 8, 'secondary': 7, 'tertiary': 6.5, 'unclassified': 5.5, 'residential': 5, 'service': 4}
d = json.load(open(osmx))
for e in d['elements']:
    t = e.get('tags', {})
    if 'geometry' not in e: continue
    pts = [pix(p['lat'], p['lon']) for p in e['geometry']]
    if 'building' in t: fill(pts, 1)
for e in d['elements']:
    t = e.get('tags', {})
    if 'geometry' not in e: continue
    pts = [pix(p['lat'], p['lon']) for p in e['geometry']]
    if t.get('amenity') == 'parking': fill(pts, 3)
    elif t.get('highway') in width: stroke(pts, 2, width[t['highway']] / 2 / px)
open(out, 'wb').write(bytes(g))
print(sum(1 for v in g if v == 1), sum(1 for v in g if v == 2), sum(1 for v in g if v == 3))
