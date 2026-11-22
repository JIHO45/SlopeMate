# 숲에 묻힌 슬로프 열기(E', docs/decisions.md 2026-11-19·22). 앱이 보여 주는 그린 선(lines-<id>.json, 미운영 closed 제외)을 따라
# STEP_M 간격으로 찍어, 가운데가 숲(앱 기준 field ≥ 0.6)인 점이 MIN_RUN개 이상 이어지는 구간만 반경 RADIUS_M 안 숲 비율을 0으로.
# 그린 선은 사용자가 지형 질감 위에 그려 대조로 확인한 슬로프라 OSM 선과 달리 전부 믿는다. 선이 이미 눈 위에 있으면 손대지 않는다.
# 필요: numpy, scipy. 사용: python open_slopes.py <maps 폴더> [리조트 id ...] [--write]  (--write 없으면 세기만)
import json, math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from islands import load, pack, field, cell_m, LEVEL

STEP_M, MIN_RUN, RADIUS_M = 3.0, 2, 5.0


def buried_runs(line, f, rc, lat_m, lon_m):
    """선을 STEP_M 간격으로 찍은 (행, 열) 점들 중 숲 속에 묻힌 연속 구간들"""
    pts = []
    for (a0, o0), (a1, o1) in zip(line, line[1:]):
        (y0, x0), (y1, x1) = rc(a0, o0), rc(a1, o1)
        n = max(1, int(math.hypot((y1 - y0) * lat_m, (x1 - x0) * lon_m) / STEP_M))
        pts += [(y0 + (y1 - y0) * t / n, x0 + (x1 - x0) * t / n) for t in range(n)]
    pts.append(rc(*line[-1]))
    runs, cur = [], []
    for y, x in pts:
        iy, ix = int(round(y)), int(round(x))
        inside = 0 <= iy < f.shape[0] and 0 <= ix < f.shape[1] and f[iy, ix] >= LEVEL
        if inside:
            cur.append((iy, ix))
        else:
            if len(cur) >= MIN_RUN: runs.append(cur)
            cur = []
    if len(cur) >= MIN_RUN: runs.append(cur)
    return runs


def open_mask(frac, lines, dem, k):
    lat_m, lon_m = cell_m(dem, k)
    rc = lambda lat, lon: ((dem['north'] - lat) / dem['step'] * k, (lon - dem['west']) / dem['step'] * k)
    f = field(frac)
    ry, rx = int(math.ceil(RADIUS_M / lat_m)), int(math.ceil(RADIUS_M / lon_m))
    yy, xx = np.mgrid[-ry:ry + 1, -rx:rx + 1]
    disk = (yy * lat_m) ** 2 + (xx * lon_m) ** 2 <= RADIUS_M ** 2
    mask = np.zeros(frac.shape, bool); length = 0.0
    for l in lines:
        for run in buried_runs(l, f, rc, lat_m, lon_m):
            length += len(run) * STEP_M
            for y, x in run:
                y0, x0 = y - ry, x - rx
                sy, sx = slice(max(0, y0), min(frac.shape[0], y + ry + 1)), slice(max(0, x0), min(frac.shape[1], x + rx + 1))
                mask[sy, sx] |= disk[sy.start - y0:sy.stop - y0, sx.start - x0:sx.stop - x0]
    return mask, length


def selftest():
    dem = {'north': 0.0, 'west': 0.0, 'step': 0.0003}
    frac = np.full((100, 100), 15, np.uint8); frac[:, :10] = 0   # 왼쪽 띠만 눈
    k = 10; lat_m, _ = cell_m(dem, k)
    line_in = [[-0.0003 * 2, 0.0003 * 5], [-0.0003 * 8, 0.0003 * 5]]     # 숲 가운데를 지나는 선(열 50)
    line_snow = [[-0.0003 * 2, 0.00003 * 3], [-0.0003 * 8, 0.00003 * 3]]  # 눈 띠 위(열 3)
    m, length = open_mask(frac, [line_in, line_snow], dem, k)
    assert m[50, 50] and not m[50, 3] and not m[50, 70] and length > 0, (m[50, 50], m[50, 3], length)
    print('ok')


if __name__ == '__main__':
    if len(sys.argv) == 1:
        selftest(); sys.exit()
    maps = sys.argv[1]; write = '--write' in sys.argv
    ids = [a for a in sys.argv[2:] if not a.startswith('--')] or sorted(f[7:-4] for f in os.listdir(maps) if f.startswith('canopy-') and f.endswith('.bin'))
    for rid in ids:
        dem = json.load(open(f'{maps}/dem-{rid}.json')); k, hk, frac, hgt = load(f'{maps}/canopy-{rid}.bin')
        lines = [l['line'] for l in json.load(open(f'{maps}/lines-{rid}.json'))['lines'] if len(l['line']) > 1 and not l.get('closed')]
        m, length = open_mask(frac, lines, dem, k)
        lat_m, lon_m = cell_m(dem, k)
        print(f'{rid:12s} 묻힌 구간 {length:6.0f}m, 여는 넓이 {(m & (frac != 255) & (frac > 0)).sum() * lat_m * lon_m / 1e4:5.2f} ha')
        if write:
            frac[m & (frac != 255)] = 0
            open(f'{maps}/canopy-{rid}.bin', 'wb').write(pack(k, hk, frac, hgt))
