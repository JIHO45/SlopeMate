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
