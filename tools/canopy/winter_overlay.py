# 겨울 덮개 PNG(EPSG:3857, 나무 높이 지도와 같은 범위, 2배 축소): 트인 땅은 흰 눈, 숲은 옅은 서리, OSM 건물·도로·주차장은 투명
# 사용: python winter_overlay.py <base(.u8/.json)> <landcover.bin> <out.png> [osm-<리조트>.json]
# OSM 슬로프 선은 폭 약 34m를 무조건 눈으로(정상부 초지·관목도 덮는다)
import json, struct, sys, zlib
import numpy as np
base, lc_path, out = sys.argv[1:4]
m = json.load(open(base + '.json')); W, H = m['width'], m['height']
h = np.fromfile(base + '.u8', np.uint8).reshape(H, W).astype(np.float32)
lc = np.fromfile(lc_path, np.uint8).reshape(H, W)
k = 1; H2, W2 = H // k, W // k
h = h[:H2 * k, :W2 * k].reshape(H2, k, W2, k).mean(axis=(1, 3))
lc = lc[:H2 * k, :W2 * k].reshape(H2, k, W2, k).max(axis=(1, 3))
def blur(a, r=1):   # 상자 평균(누적합, 가로·세로 분리)
    a = a.astype(np.float32)
    for ax in (0, 1):
        p = np.pad(a, [(r + 1, r) if i == ax else (0, 0) for i in range(2)], mode='edge').cumsum(axis=ax)
        n = a.shape[ax]
        a = (np.take(p, range(2 * r + 1, 2 * r + 1 + n), axis=ax) - np.take(p, range(0, n), axis=ax)) / (2 * r + 1)
    return a
f = np.clip((h - 2.5) / 3.5, 0, 1); f = blur(f, 1)          # 숲 0~1
# 건물 둘레 약 12m는 나무 높이 지도가 지붕·그림자를 나무로 읽으므로 숲이 아님
near_bld = np.clip(blur((lc == 1).astype(np.float32), 12) * 6, 0, 1)
f = f * (1 - near_bld)
if len(sys.argv) > 4:   # 슬로프 띠
    import math
    R = 6378137.0; px = m['pixel_m'] * k
    band = np.zeros_like(f); rr = int(17 / (m['pixel_m'] * math.cos(math.radians(37.63))) / k) + 1
    yy, xx = np.mgrid[-rr:rr + 1, -rr:rr + 1]; disk = (xx * xx + yy * yy <= rr * rr)
    for sl in json.load(open(sys.argv[4]))['slopes']:
        for l in sl['lines']:
            for (a, b), (c, d) in zip(l, l[1:]):
                x1 = (R * math.radians(b) - m['x0']) / px; y1 = (m['y0'] - R * math.log(math.tan(math.pi / 4 + math.radians(a) / 2))) / px
                x2 = (R * math.radians(d) - m['x0']) / px; y2 = (m['y0'] - R * math.log(math.tan(math.pi / 4 + math.radians(c) / 2))) / px
                n = int(max(abs(x2 - x1), abs(y2 - y1))) + 1
                for i in range(0, n + 1, max(1, rr // 2)):
                    cx = int(x1 + (x2 - x1) * i / n); cy = int(y1 + (y2 - y1) * i / n)
                    if rr <= cx < W2 - rr and rr <= cy < H2 - rr: band[cy - rr:cy + rr + 1, cx - rr:cx + rr + 1] = np.maximum(band[cy - rr:cy + rr + 1, cx - rr:cx + rr + 1], disk)
    band = blur(band, 3)
    f = f * (1 - band)
# 겨울 숲: 수관은 잎 진 활엽 회갈색 ↔ 키 큰 침엽 어두운 녹색, 수관 사이 빈 곳은 눈, 북서 빛으로 수관 결
mean = blur(h, 3)
gap = np.clip((mean - h + 1) / 4, 0.25, 1)
dark = np.clip((h - 12) / 10, 0, 1)
crown = np.array([150, 158, 170]) * (1 - dark[..., None]) + np.array([60, 80, 78]) * dark[..., None]
p = np.pad(h, 1, mode='edge'); relief = np.clip((p[:-2, :-2] - p[2:, 2:]) * 0.035, -0.35, 0.35)
crown = crown * (1 + relief[..., None])
snow = np.array([244, 247, 252])
forest = crown * (1 - 0.65 * gap[..., None]) + snow * 0.65 * gap[..., None]
alpha = (1 - f) * 0.85 + f * 0.62
if len(sys.argv) > 4: alpha = np.maximum(alpha, band * 0.96)   # 슬로프 띠는 거의 불투명(사진 속 여름 길 가림)
#                           # 트인 땅 눈 0.85, 숲(우리 겨울 숲) 0.62
alpha *= 1 - blur((lc > 0).astype(np.float32), 2)            # 건물·도로·주차장은 투명(가장자리 흐림)
rgb = snow * (1 - f[..., None]) + forest * f[..., None]
# 가장자리 400m는 알파를 0까지(덮개 밖 봄 산과 이음매를 흐리게)
e = int(400 / (m['pixel_m'] * 0.79 * k)); ys, xs = np.mgrid[0:H2, 0:W2]
edge = np.minimum(np.minimum(ys, H2 - 1 - ys), np.minimum(xs, W2 - 1 - xs)) / e
alpha *= np.clip(edge, 0, 1) ** 1.5
img = np.concatenate([rgb, (alpha * 255)[..., None]], -1).clip(0, 255).astype(np.uint8)
raw = b''.join(b'\0' + img[y].tobytes() for y in range(H2))
ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
open(out, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', W2, H2, 8, 6, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw, 6)) + ch(b'IEND', b''))
print(W2, H2)
