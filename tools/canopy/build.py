# 앱용 숲 파일: 나무 높이 지도(EPSG:3857 .u8/.json, extract.py에 dem-<id>.json을 넣어 DEM 범위로 받은 것)를 DEM 격자(1초)에 맞춘 두 판으로 줄인다.
#   숲 비율 판: DEM 칸을 K배로 나눈 칸(K=10이면 약 3m). 값 = 높이 4m 이상 원본 화소 비율 0~15, 범위 밖 255.
#   나무 높이 판: DEM 칸을 HK배로 나눈 칸(약 15m). 값 = 그 칸 숲 화소 평균 높이 ÷ 2m(0~15 = 0~30m). 그림자 길이·숲 결용.
# 파일: b'CNP2' + K(u8) + HK(u8) + 숲 판 너비·높이(u16 LE) + raw DEFLATE(숲 판 바이트 + 높이 판 바이트). 앱 Terrain3D.Canopy가 읽는다.
# 사용: tools/dem/.venv/bin/python tools/canopy/build.py <chm 접두어> SlopeMate/Resources/maps/dem-<id>.json <out.bin> [K=10] [HK=2] [확인용.png]
#   숲 띠 틈 메우기: GAP_FILL=SlopeMate/Resources/maps/osm-<id>.json GAP_M=30 을 붙인다. 2026-11-17 기준 에덴밸리·용평 빼고 10곳이 30m(docs/decisions.md).
import json, math, struct, sys, zlib
import numpy as np

def boxes(h, meta, dem, K):
    """원본 화소를 (rows-1)K × (cols-1)K 칸으로 나눈 경계와 칸별 합 함수"""
    R = 6378137.0; px = meta['pixel_m']
    oh, ow = (dem['rows'] - 1) * K, (dem['cols'] - 1) * K
    # 출력 화소 경계(위도는 행에만, 경도는 열에만 달린다)
    lat = dem['north'] - np.arange(oh + 1) / K * dem['step']
    lon = dem['west'] + np.arange(ow + 1) / K * dem['step']
    ys = (meta['y0'] - R * np.log(np.tan(np.pi / 4 + np.radians(lat) / 2))) / px
    xs = (R * np.radians(lon) - meta['x0']) / px
    yi = np.clip(np.round(ys).astype(int), 0, h.shape[0]); xi = np.clip(np.round(xs).astype(int), 0, h.shape[1])
    a, b = yi[:-1, None], yi[1:, None]; c, d = xi[None, :-1], xi[None, 1:]
    def boxsum(v):   # 적분 영상
        I = np.zeros((h.shape[0] + 1, h.shape[1] + 1), np.int64); I[1:, 1:] = v.cumsum(0).cumsum(1)
        return I[b, d] - I[a, d] - I[b, c] + I[a, c]
    outside = np.zeros((oh, ow), bool)   # 원본 범위 밖(받은 범위가 DEM보다 좁을 때)
    outside[(ys[:-1] < 0) | (ys[1:] > h.shape[0]), :] = True
    outside[:, (xs[:-1] < 0) | (xs[1:] > h.shape[1])] = True
    return boxsum, (b - a) * (d - c), outside

def build(h, meta, dem, K, HK=2):
    """반환: (숲 비율 판 uint8, 나무 높이 판 uint8)"""
    f = (h >= 4).astype(np.int32)
    boxsum, n, outside = boxes(h, meta, dem, K)
    frac = np.where((n > 0) & ~outside, np.round(15 * boxsum(f) / np.maximum(n, 1)), 255).astype(np.uint8)
    boxsum2, _, _ = boxes(h, meta, dem, HK)
    s, hs = boxsum2(f), boxsum2(h.astype(np.int32) * f)
    hgt = np.clip(np.round(hs / np.maximum(s, 1) / 2), 0, 15).astype(np.uint8)
    return frac, hgt

def fill_gaps(frac, dem, K, slopes, gap_m=15.0, keep_m=6.0):
    """숲 띠 사이 짧은 틈(약 gap_m 이하)을 숲으로 메운다(닫힘 = 최대 후 최소). OSM 슬로프 선 keep_m 안은 원래 값 유지.
    원본 위성 모델이 한두 줄 나무 띠를 군데군데 놓쳐 생긴 끊김을 잇는 용도. 긴 틈은 그대로 둔다."""
    lat_m = dem['step'] * 111320 / K
    lon_m = lat_m * math.cos(math.radians(dem['north']))
    def shifts(rad):
        ry, rx = int(rad / lat_m), int(rad / lon_m)
        return [(dy, dx) for dy in range(-ry, ry + 1) for dx in range(-rx, rx + 1)
                if (dy * lat_m) ** 2 + (dx * lon_m) ** 2 <= rad * rad]
    def morph(a, rad, op):
        r = max(int(rad / min(lat_m, lon_m)), 1); pad = np.pad(a, r, mode='edge'); out = a.copy()
        for dy, dx in shifts(rad):
            out = op(out, pad[r + dy:r + dy + a.shape[0], r + dx:r + dx + a.shape[1]])
        return out
    out = np.where(frac == 255, 0, frac).astype(np.uint8)
    closed = morph(morph(out, gap_m / 2, np.maximum), gap_m / 2, np.minimum)
    keep = np.zeros(frac.shape, bool)   # 슬로프 선을 칸에 찍고 keep_m만큼 넓힌다
    for line in slopes:
        for (a0, o0), (a1, o1) in zip(line, line[1:]):
            n = int(max(abs(a1 - a0) * 111320 / lat_m, abs(o1 - o0) * 111320 * math.cos(math.radians(a0)) / lon_m) * 2) + 1
            t = np.linspace(0, 1, n + 1)
            y = np.round((dem['north'] - (a0 + (a1 - a0) * t)) / dem['step'] * K).astype(int)
            x = np.round(((o0 + (o1 - o0) * t) - dem['west']) / dem['step'] * K).astype(int)
            ok = (y >= 0) & (y < frac.shape[0]) & (x >= 0) & (x < frac.shape[1])
            keep[y[ok], x[ok]] = True
    keep = morph(keep, keep_m, np.logical_or)
    return np.where(frac == 255, 255, np.where(keep, out, closed)).astype(np.uint8)

def pack(frac, hgt, K, HK):
    z = zlib.compressobj(9, zlib.DEFLATED, -15); body = z.compress(frac.tobytes() + hgt.tobytes()) + z.flush()
    return b'CNP2' + struct.pack('<BBHH', K, HK, frac.shape[1], frac.shape[0]) + body

if __name__ == '__main__' and len(sys.argv) == 1:   # 자체 확인: 왼쪽 반 숲(10m)인 합성 격자
    dem = {'north': 0.001, 'west': 0.0, 'step': 0.0005, 'rows': 3, 'cols': 3}
    R = 6378137.0
    meta = {'pixel_m': 1.0, 'x0': 0.0, 'y0': R * math.log(math.tan(math.pi / 4 + math.radians(0.001) / 2))}
    W = int(R * math.radians(0.001)) + 1
    h = np.zeros((W, W), np.uint8); h[:, :W // 2] = 10
    fr, hg = build(h, meta, dem, 2, 1)
    assert fr.shape == (4, 4) and hg.shape == (2, 2), (fr.shape, hg.shape)
    assert (fr[:, 0] == 15).all() and (fr[:, 3] == 0).all() and (hg[:, 0] == 5).all(), (fr, hg)
    b = pack(fr, hg, 2, 1); raw = zlib.decompress(b[10:], -15)
    assert b[:4] == b'CNP2' and raw[:16] == fr.tobytes() and raw[16:] == hg.tobytes()
    print('ok')
elif __name__ == '__main__':
    pre, dem_path, out = sys.argv[1:4]; K = int(sys.argv[4]) if len(sys.argv) > 4 else 10; HK = int(sys.argv[5]) if len(sys.argv) > 5 else 2
    meta = json.load(open(pre + '.json')); dem = json.load(open(dem_path))
    h = np.fromfile(pre + '.u8', np.uint8).reshape(meta['height'], meta['width'])
    fr, hg = build(h, meta, dem, K, HK)
    import os
    if os.environ.get('GAP_FILL'):   # 시험: GAP_FILL=<osm-<id>.json> 이면 짧은 틈 메우기
        osm = json.load(open(os.environ['GAP_FILL']))
        before = np.mean(fr[fr != 255] >= 8)
        fr = fill_gaps(fr, dem, K, [l for s_ in osm['slopes'] for l in s_['lines'] if len(l) > 1], float(os.environ.get('GAP_M', 15)))
        print(f'틈 메우기: 숲(≥50%) 칸 {before * 100:.1f}% → {np.mean(fr[fr != 255] >= 8) * 100:.1f}%')
    b = pack(fr, hg, K, HK); open(out, 'wb').write(b)
    print(f'숲 {fr.shape[1]}x{fr.shape[0]} K={K}, 높이 {hg.shape[1]}x{hg.shape[0]} HK={HK} → {len(b) / 1024:.0f} KB (풀면 {(fr.size + hg.size) / 1e6:.1f} MB), 범위 밖 {np.mean(fr == 255) * 100:.1f}%')
    if len(sys.argv) > 6:   # 확인용 PNG(숲 비율 → 진함, 범위 밖 빨강)
        v = np.where(fr == 255, 0, 255 - fr.astype(np.int32) * 14).astype(np.uint8)
        rgb = np.stack([np.where(fr == 255, 200, v), v, v], -1).astype(np.uint8)
        raw = b''.join(b'\0' + rgb[y].tobytes() for y in range(fr.shape[0]))
        ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
        open(sys.argv[6], 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', fr.shape[1], fr.shape[0], 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw, 6)) + ch(b'IEND', b''))
