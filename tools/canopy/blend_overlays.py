# MapKit 혼합 덮개 두 장(EPSG:3857, 나무 높이 지도와 같은 범위·해상도)
#   <out>-forest.png: 숲(수관) 범위에 청회색, 알파 = 숲 정도 → MapKit .color 혼합(명암은 사진, 색은 겨울)
#   <out>-snow.png:   흰색 .screen 혼합(밝기만 올림). 트인 땅(숲·건물·도로·주차장 제외) 0.62, 슬로프 중심선 45m 안 0.85, 숲 위 0.30(봄 숲 밝기를 겨울 숲 40~45%로)
# 사용: python blend_overlays.py <base(.u8/.json)> <landcover.bin> <osm-<리조트>.json> <out 접두어>
import json, math, struct, sys, zlib
import numpy as np
base, lc_path, osm, out = sys.argv[1:5]
m = json.load(open(base + '.json')); W, H = m['width'], m['height']
h = np.fromfile(base + '.u8', np.uint8).reshape(H, W).astype(np.float32)
lc = np.fromfile(lc_path, np.uint8).reshape(H, W)

def blur(a, r):   # 상자 평균(누적합)
    a = a.astype(np.float32)
    for ax in (0, 1):
        p = np.pad(a, [(r + 1, r) if i == ax else (0, 0) for i in range(2)], mode='edge').cumsum(axis=ax)
        n = a.shape[ax]
        a = (np.take(p, range(2 * r + 1, 2 * r + 1 + n), axis=ax) - np.take(p, range(0, n), axis=ax)) / (2 * r + 1)
    return a

gm = m['pixel_m'] * math.cos(math.radians(37.63))   # 지상 m / 픽셀
built = blur((lc > 0).astype(np.float32), 2) > 0.02
near_bld = np.clip(blur((lc == 1).astype(np.float32), int(12 / gm)) * 6, 0, 1)
forest = np.clip((h - 2.5) / 3.5, 0, 1)
forest = blur(forest, 1) * (1 - near_bld)

# 슬로프 중심선 45m 안(활주 구역)
R = 6378137.0; px = m['pixel_m']
zone = np.zeros((H, W), np.float32); rr = int(45 / gm)
yy, xx = np.mgrid[-rr:rr + 1, -rr:rr + 1]; disk = (xx * xx + yy * yy <= rr * rr).astype(np.float32)
for sl in json.load(open(osm))['slopes']:
    for l in sl['lines']:
        for (a, b), (c, d) in zip(l, l[1:]):
            x1 = (R * math.radians(b) - m['x0']) / px; y1 = (m['y0'] - R * math.log(math.tan(math.pi / 4 + math.radians(a) / 2))) / px
            x2 = (R * math.radians(d) - m['x0']) / px; y2 = (m['y0'] - R * math.log(math.tan(math.pi / 4 + math.radians(c) / 2))) / px
            n = int(max(abs(x2 - x1), abs(y2 - y1))) + 1
            for i in range(0, n + 1, max(1, rr // 3)):
                cx = int(x1 + (x2 - x1) * i / n); cy = int(y1 + (y2 - y1) * i / n)
                if rr <= cx < W - rr and rr <= cy < H - rr:
                    zone[cy - rr:cy + rr + 1, cx - rr:cx + rr + 1] = np.maximum(zone[cy - rr:cy + rr + 1, cx - rr:cx + rr + 1], disk)
zone = blur(zone, int(10 / gm))
open_ = np.clip(1 - forest * 1.4, 0, 1) * (1 - built)
snow = np.maximum(open_ * np.maximum(0.62, zone * 0.85), forest * 0.30 * (1 - built))
snow = blur(snow, 2)

# 가장자리 400m 페이드
e = int(400 / gm); ys, xs = np.mgrid[0:H, 0:W]
edge = np.clip(np.minimum(np.minimum(ys, H - 1 - ys), np.minimum(xs, W - 1 - xs)) / e, 0, 1) ** 1.5

def png(path, rgb, a):
    img = np.concatenate([np.broadcast_to(np.array(rgb, np.float32), (H, W, 3)), (a * 255)[..., None]], -1).clip(0, 255).astype(np.uint8)
    raw = b''.join(b'\0' + img[y].tobytes() for y in range(H))
    ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw, 6)) + ch(b'IEND', b''))

png(out + '-forest.png', (122, 132, 142), forest * 0.85 * edge)
png(out + '-snow.png', (228, 236, 246), snow * edge)
print(W, H, float(forest.mean()), float(snow.mean()))
