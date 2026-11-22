# 슬로프 폭 보장(docs/decisions.md 2026-11-22). 앱이 보여 주는 그린 선(lines-<id>.json, 미운영 closed 제외)을 STEP_M 간격으로 찍어
# 반경 RADIUS_M 안 숲 비율을 0으로 한다(폭 30m). 숲 지도가 슬로프를 숲으로 놓쳤거나 실제보다 좁게 잡은 곳을 연다.
# 그린 선은 사용자가 지형 질감 위에 그려 대조로 확인한 슬로프라 OSM 선과 달리 전부 믿는다. 이미 넓은 슬로프는 그대로.
# 필요: numpy, scipy. 사용: python open_slopes.py <maps 폴더> [리조트 id ...] [--write]  (--write 없으면 세기만, 인자 없으면 자체 확인)
import json, math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from islands import load, pack, field, cell_m, LEVEL

STEP_M, RADIUS_M = 3.0, 15.0


def open_mask(frac, lines, dem, k, radius=RADIUS_M):
    """그린 선 반경 radius 안 칸"""
    lat_m, lon_m = cell_m(dem, k)
    rc = lambda lat, lon: ((dem['north'] - lat) / dem['step'] * k, (lon - dem['west']) / dem['step'] * k)
    ry, rx = int(math.ceil(radius / lat_m)), int(math.ceil(radius / lon_m))
    yy, xx = np.mgrid[-ry:ry + 1, -rx:rx + 1]
    disk = (yy * lat_m) ** 2 + (xx * lon_m) ** 2 <= radius ** 2
    mask = np.zeros(frac.shape, bool)
    for l in lines:
        for (a0, o0), (a1, o1) in zip(l, l[1:]):
            (y0, x0), (y1, x1) = rc(a0, o0), rc(a1, o1)
            n = max(1, int(math.hypot((y1 - y0) * lat_m, (x1 - x0) * lon_m) / STEP_M))
            for t in range(n + 1):
                y, x = int(round(y0 + (y1 - y0) * t / n)), int(round(x0 + (x1 - x0) * t / n))
                sy = slice(max(0, y - ry), min(frac.shape[0], y + ry + 1)); sx = slice(max(0, x - rx), min(frac.shape[1], x + rx + 1))
                if sy.start >= sy.stop or sx.start >= sx.stop: continue
                mask[sy, sx] |= disk[sy.start - (y - ry):sy.stop - (y - ry), sx.start - (x - rx):sx.stop - (x - rx)]
    return mask


def selftest():
    dem = {'north': 0.0, 'west': 0.0, 'step': 0.0003}
    k = 10; lat_m, lon_m = cell_m(dem, k)   # 칸 약 3.3m
    frac = np.full((100, 100), 15, np.uint8)
    line = [[-0.00003 * 10, 0.00003 * 50], [-0.00003 * 90, 0.00003 * 50]]   # 열 50을 따라 세로
    m = open_mask(frac, [line], dem, k)
    assert m[50, 50] and m[50, 54] and not m[50, 56] and not m[50, 70], (m[50, 54], m[50, 56])   # 반경 15m ≈ 4.5칸
    print('ok')


if __name__ == '__main__':
    if len(sys.argv) == 1:
        selftest(); sys.exit()
    maps = sys.argv[1]; write = '--write' in sys.argv
    ids = [a for a in sys.argv[2:] if not a.startswith('--')] or sorted(f[7:-4] for f in os.listdir(maps) if f.startswith('canopy-') and f.endswith('.bin'))
    for rid in ids:
        dem = json.load(open(f'{maps}/dem-{rid}.json')); k, hk, frac, hgt = load(f'{maps}/canopy-{rid}.bin')
        lines = [l['line'] for l in json.load(open(f'{maps}/lines-{rid}.json'))['lines'] if len(l['line']) > 1 and not l.get('closed')]
        m = open_mask(frac, lines, dem, k)
        lat_m, lon_m = cell_m(dem, k)
        print(f'{rid:12s} 여는 숲 {(m & (field(frac) >= LEVEL)).sum() * lat_m * lon_m / 1e4:5.2f} ha')
        if write:
            frac[m & (frac != 255)] = 0
            open(f'{maps}/canopy-{rid}.bin', 'wb').write(pack(k, hk, frac, hgt))
