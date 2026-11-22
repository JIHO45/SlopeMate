# 외딴 작은 숲 덩어리 빼기(A, docs/decisions.md 2026-11-19). 숲 = 앱과 같은 기준(숲 판 3×3 이항 평균 ≥ 0.6).
# 서로 이어진(8방향) 숲 덩어리 중 넓이 AREA_M2 미만인 것만 숲 비율 0으로. 가는 숲 띠도 큰 숲과 이어져 있으면 남는다. 나무 높이 판은 그대로.
# 필요: numpy, scipy. 사용: python islands.py <maps 폴더> [리조트 id ...] [--write]  (--write 없으면 세기만)
import math, json, os, struct, sys, zlib
import numpy as np
from scipy import ndimage

AREA_M2 = 500
LEVEL = 0.6

def load(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'CNP2'
    k, hk = b[4], b[5]; w, h = struct.unpack('<HH', b[6:10])
    raw = zlib.decompress(b[10:], -15)
    return k, hk, np.frombuffer(raw[:w * h], np.uint8).reshape(h, w).copy(), raw[w * h:]

def pack(k, hk, frac, hgt):
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    return b'CNP2' + struct.pack('<BBHH', k, hk, frac.shape[1], frac.shape[0]) + z.compress(frac.tobytes() + hgt) + z.flush()

def field(frac):
    """앱 Terrain3D.Canopy.field와 같은 값(범위 밖 255는 0)"""
    f = np.where(frac == 255, 0, frac).astype(np.float32) / 15
    w = np.array([1, 2, 1], np.float32)
    return ndimage.convolve(f, np.outer(w, w) / 16, mode='nearest')

def cell_m(dem, k):
    lat_m = dem['step'] * 111320 / k
    return lat_m, lat_m * math.cos(math.radians(dem['north']))

def small_islands(frac, lat_m, lon_m, area=AREA_M2):
    """지울 칸(외딴 작은 숲 덩어리)과 덩어리 수"""
    m = field(frac) >= LEVEL
    lab, n = ndimage.label(m, structure=np.ones((3, 3)))
    sizes = ndimage.sum(m, lab, index=np.arange(1, n + 1)) * lat_m * lon_m
    small = np.zeros(n + 1, bool); small[1:] = sizes < area
    return small[lab], int(small.sum())

if __name__ == '__main__':
    if len(sys.argv) == 1:   # 자체 확인: 10×10m 덩어리는 지우고 큰 숲은 남긴다
        frac = np.zeros((60, 60), np.uint8); frac[5:9, 5:9] = 15; frac[20:60, 20:60] = 15
        rm, n = small_islands(frac, 3.0, 3.0)
        assert n == 1 and rm[6, 6] and not rm[40, 40], (n,)
        print('ok'); sys.exit()
    maps = sys.argv[1]; write = '--write' in sys.argv
    ids = [a for a in sys.argv[2:] if not a.startswith('--')] or sorted(f[7:-4] for f in os.listdir(maps) if f.startswith('canopy-') and f.endswith('.bin'))
    for rid in ids:
        dem = json.load(open(f'{maps}/dem-{rid}.json')); k, hk, frac, hgt = load(f'{maps}/canopy-{rid}.bin')
        lat_m, lon_m = cell_m(dem, k)
        rm, n = small_islands(frac, lat_m, lon_m)
        print(f'{rid:12s} 덩어리 {n:5d}개, {rm.sum() * lat_m * lon_m / 1e4:6.2f} ha')
        if write:
            frac[rm & (frac != 255)] = 0
            open(f'{maps}/canopy-{rid}.bin', 'wb').write(pack(k, hk, frac, hgt))
