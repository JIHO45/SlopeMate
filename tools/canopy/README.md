# 나무 높이 지도 도구 (R50, K)

Meta·WRI 나무 높이 지도 v2(CC BY 4.0, EPSG:3857, 픽셀 약 1.19m, 용평 위도에서 지상 약 0.95m)를 리조트 범위로 잘라 받고 확인 그림을 만든다. 앱에는 아직 넣지 않았다(decisions 2026-11-15 "공개 데이터 3D 시험판과 Mapbox 실험").

```bash
# 리조트 OSM 범위 + 800m를 zoom-10 quadkey COG에서 모자이크 → <out>.u8 / .json / .png
python3 tools/canopy/extract.py tools/canopy 'https://data.source.coop/tge-labs/meta-chm-v2/chm/{}.tif' SlopeMate/Resources/maps/osm-yongpyong.json out/yongpyong
python3 tools/canopy/overlay.py out/yongpyong SlopeMate/Resources/maps/osm-yongpyong.json out/yp-osm.png      # 슬로프 중심선 겹치기
python3 tools/canopy/overlay_th.py out/yongpyong SlopeMate/Resources/maps/osm-yongpyong.json out/yp-th8.png 8  # 8m 문턱 흑백
python3 tools/canopy/overlay_osm.py out/yongpyong <overpass.json> SlopeMate/Resources/maps/osm-yongpyong.json out/yp-osmx.png  # 건물·주차장·골프장 윤곽
python3 tools/canopy/landcover.py out/yongpyong <overpass.json> out/landcover.bin                              # 건물 1·도로 2·주차장 3 (같은 격자)
```

- 받은 데이터(`.u8`, 리조트당 약 24MB)는 저장소에 넣지 않는다.
- `prototype-v2.diff`: 시험 복사본의 `Terrain3D`·`Map3DScene` 변경(숲 면·눈 3단·OSM 건물·이름표·출발/도착 표식). 용평 상수가 박힌 시험 코드라 그대로 적용하지 않는다.
- 출처 표기: "Meta·WRI 나무 높이 지도(CC BY 4.0)". 인용: Tolan et al. 2024, Brandt et al. 2026.

## 슬로프·숲 대조 그림 (`review.py`)

숲 지도가 슬로프를 숲으로 잡은 자리를 사람이 찾는 그림이다(docs/decisions.md 2026-11-19). 위에서 본 숲(앱과 같은 기준) 위에 OSM 슬로프 선(색 = 난이도, 번호·이름 범례)과 리프트를 앱 3D와 같은 방향(위가 남쪽)으로 그린다. 공식 맵·위성 사진은 옆에 두고 판단에만 쓰고 따라 그리지 않는다.

    python review.py <출력 폴더> ../../SlopeMate/Resources/maps <리조트 id> [lat0 lat1 lon0 lon1]

numpy, scipy, pillow가 필요하다. 마지막 네 값을 주면 그 범위를 주황 상자로 표시한다.

## 숲 파일 정리 (`islands.py`, `open_slopes.py`)

docs/decisions.md 2026-11-22. 순서대로 돌린다(둘 다 `--write` 없으면 세기만, 인자 없이 돌리면 자체 확인).

    python islands.py ../../SlopeMate/Resources/maps --write       # 외딴 숲 덩어리 500㎡ 미만 빼기
    python open_slopes.py ../../SlopeMate/Resources/maps --write   # 그린 선 양쪽 15m(폭 30m) 숲 지우기
    python islands.py ../../SlopeMate/Resources/maps --write       # 열기로 생긴 조각 정리

그린 선 고침은 `line_fixes.py`(이름·난이도·연결·삭제·미운영·구간, 한 번만 적용). 도구 환경은 `.venv`(git 제외, numpy·scipy·pillow).
