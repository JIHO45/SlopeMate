#!/usr/bin/env python3
"""Copernicus DEM GLO-30을 리조트 범위로 잘라 앱 내장 고도 격자로 만든다 (R50, K; 05-design 4장 "내장 고도 격자와 지형 바탕").

사용: tools/dem/.venv/bin/python tools/dem/build.py [리조트 ID ...]   (없으면 전체)
준비: python3 -m venv tools/dem/.venv && tools/dem/.venv/bin/pip install rasterio
출력: SlopeMate/Resources/maps/dem-<리조트>.json

- 범위: osm-<리조트>.json의 슬로프·리프트 좌표 범위 + 사방 여백 max(긴 변의 85%, 1500m).
  한 변이 400칸을 넘으면 그 방향 여백을 줄여 맞춘다(슬로프·리프트 범위는 늘 포함).
- 원본 타일(1도 단위 COG)은 AWS 공개 버킷 copernicus-dem-30m에서 tools/dem/cache/에 받는다(저장소에 올리지 않음).
  https://copernicus-dem-30m.s3.amazonaws.com/Copernicus_DSM_COG_10_N37_00_E128_00_DEM/Copernicus_DSM_COG_10_N37_00_E128_00_DEM.tif
- 격자는 다시 계산하지 않고 원본 칸(위경도 1초) 그대로 자른다.
- 파일: north·west는 첫 행·첫 열 칸의 "중심" 위경도(GLO-30은 칸 중심이 정수 초에 온다), step은 칸 간격(도).
  heights는 0.1m 단위 Int16 리틀 엔디언을 base64로, 북쪽 행부터, 행 안은 서→동.
- 데이터: produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018
  provided under COPERNICUS by the European Union and ESA; all rights reserved
"""
import base64, json, math, subprocess, sys
from datetime import date
from pathlib import Path

import numpy as np
import rasterio
from rasterio.merge import merge

from orient_lifts import orient

ROOT = Path(__file__).resolve().parents[2]
RESORTS = ROOT / "SlopeMate/Resources/resorts.json"
MAPS = ROOT / "SlopeMate/Resources/maps"
CACHE = Path(__file__).with_name("cache")
BUCKET = "https://copernicus-dem-30m.s3.amazonaws.com"
SOURCE = ("produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 "
          "provided under COPERNICUS by the European Union and ESA; all rights reserved")
MARGIN, MIN_MARGIN_M, MAX_CELLS = 0.85, 1500, 400
STEP = 1 / 3600  # GLO-30 칸 간격(위도 50도 아래는 경위도 모두 1초)
M_PER_DEG = 111320


def tile(lat, lon):
    """남서 모서리 정수 위경도의 타일 파일. 없거나 못 받으면 None"""
    name = f"Copernicus_DSM_COG_10_{'N' if lat >= 0 else 'S'}{abs(lat):02d}_00_{'E' if lon >= 0 else 'W'}{abs(lon):03d}_00_DEM"
    path = CACHE / f"{name}.tif"
    if not path.exists():
        CACHE.mkdir(exist_ok=True)
        part = path.with_suffix(".part")
        r = subprocess.run(["curl", "-sfL", "-o", str(part), f"{BUCKET}/{name}/{name}.tif"])
        if r.returncode != 0:
            part.unlink(missing_ok=True)
            print(f"  타일 없음: {name}", file=sys.stderr)
            return None
        part.rename(path)
    return path


def bounds(rid):
    doc = json.loads((MAPS / f"osm-{rid}.json").read_text())
    pts = [p for s in doc["slopes"] for line in s["lines"] for p in line] + [p for l in doc["lifts"] for p in l["line"]]
    lats, lons = [p[0] for p in pts], [p[1] for p in pts]
    s, n, w, e = min(lats), max(lats), min(lons), max(lons)
    k = math.cos(math.radians((s + n) / 2))
    long_m = max((n - s) * M_PER_DEG, (e - w) * M_PER_DEG * k)
    m = max(long_m * MARGIN, MIN_MARGIN_M)
    # 칸 경계 맞춤으로 양쪽 한 칸씩 늘 수 있으니 2칸 남긴다
    cap = lambda span, deg: min(deg, max(0, ((MAX_CELLS - 2) * STEP - span) / 2))
    ml, mo = cap(n - s, m / M_PER_DEG), cap(e - w, m / (M_PER_DEG * k))
    return s - ml, n + ml, w - mo, e + mo


def build(rid):
    s, n, w, e = bounds(rid)
    paths = [tile(la, lo) for la in range(math.floor(s), math.floor(n) + 1) for lo in range(math.floor(w), math.floor(e) + 1)]
    if not paths or None in paths:
        return None
    srcs = [rasterio.open(p) for p in paths]
    try:
        # 범위를 원본 칸 경계에 맞춰 넓힌다(안 맞추면 merge가 칸을 반 칸까지 어긋나게 다시 뽑는다)
        t0 = srcs[0].transform
        snap = lambda v, o, r, f: o + f((v - o) / r) * r
        w, e = snap(w, t0.c, t0.a, math.floor), snap(e, t0.c, t0.a, math.ceil)
        s, n = snap(s, t0.f, t0.e, math.ceil), snap(n, t0.f, t0.e, math.floor)
        arr, tf = merge(srcs, bounds=(w, s, e, n))
    finally:
        for d in srcs:
            d.close()
    z = arr[0]
    step = tf.a
    assert abs(step + tf.e) < 1e-12, "위경도 칸 간격이 같아야 한다"
    north, west = tf.f + tf.e / 2, tf.c + tf.a / 2  # 첫 칸 중심
    q = np.clip(np.round(np.nan_to_num(z, nan=0) * 10), -32768, 32767).astype("<i2")
    return {"resort_id": rid, "source": SOURCE, "generated": date.today().isoformat(),
            "north": round(north, 8), "west": round(west, 8), "step": step,
            "rows": int(q.shape[0]), "cols": int(q.shape[1]),
            "heights": base64.b64encode(q.tobytes()).decode()}


def main():
    ids = sys.argv[1:] or [r["id"] for r in json.loads(RESORTS.read_text())]
    total = 0
    for rid in ids:
        if not (MAPS / f"osm-{rid}.json").exists():
            print(f"{rid}: OSM 파일 없음, 건너뜀", file=sys.stderr)
            continue
        doc = build(rid)
        if doc is None:
            print(f"{rid}: 고도 데이터 없음, 건너뜀", file=sys.stderr)
            continue
        path = MAPS / f"dem-{rid}.json"
        path.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
        size = path.stat().st_size
        total += size
        print(f"{rid}: {doc['rows']}×{doc['cols']}칸, {size / 1024:.0f}KB")
        orient(rid)  # 새 리조트 첫 실행: OSM이 먼저 만들어져 orient를 건너뛰었을 수 있다
    print(f"합계 {total / 1024:.0f}KB")


if __name__ == "__main__":
    main()
