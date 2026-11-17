"""우리 ID 유지 규칙 확인: python3 tools/osm/test_ids.py"""
from build import assign_ids, shown_name


def run(old, new):
    items = [dict(x) for x in new]
    return assign_ids("r", items, old, "s")


def ids(out):
    return {x["name"]: x["id"] for x in out[0]}


a = {"name": "A", "difficulty": "easy", "osm_ids": ["way/1"]}
b = {"name": "B", "difficulty": "easy", "osm_ids": ["way/2"]}
c = {"name": "C", "difficulty": "easy", "osm_ids": ["way/3"]}

first = run({"items": [], "retired": []}, [a, b, c])
assert ids(first) == {"A": "r-s01", "B": "r-s02", "C": "r-s03"}
state = lambda out: {"items": out[0], "retired": out[1]}

# 새 슬로프 추가: 기존 ID 그대로, 새 번호
d = {"name": "D", "difficulty": "easy", "osm_ids": ["way/4"]}
out = run(state(first), [a, b, c, d])
assert ids(out) == {"A": "r-s01", "B": "r-s02", "C": "r-s03", "D": "r-s04"}

# C 삭제(가장 큰 번호) → retired에 남고, 다음에 생긴 E가 s03을 다시 받지 않음
out = run(state(out), [a, b, d])
assert [x["id"] for x in out[1]] == ["r-s03"]
e = {"name": "E", "difficulty": "easy", "osm_ids": ["way/5"]}
out2 = run(state(out), [a, b, d, e])
assert ids(out2)["E"] == "r-s05" and [x["id"] for x in out2[1]] == ["r-s03"]

# C를 OSM에서 지우고 다시 그림(새 way ID, 같은 이름·난이도) → 옛 ID 복원
out3 = run(state(out2), [a, b, d, e, {**c, "osm_ids": ["way/99"]}])
assert ids(out3)["C"] == "r-s03" and out3[1] == []

# A·B 선이 하나의 relation으로 묶임 → 구성 선이 겹치는 첫 ID를 이어 받음
rel = {"name": "AB", "difficulty": "easy", "osm_ids": ["relation/7", "way/1", "way/2"]}
out4 = run(state(out3), [rel, d, e])
assert ids(out4)["AB"] == "r-s01" and "r-s02" in [x["id"] for x in out4[1]]

# 같은 이름·난이도가 둘이면 이름으로 잇지 않음(틀린 이름보다 새 번호가 낫다)
twins = {"items": [], "retired": [{"id": "r-s01", "name": "X", "difficulty": "easy", "osm_ids": ["way/1"]},
                                  {"id": "r-s02", "name": "X", "difficulty": "easy", "osm_ids": ["way/2"]}]}
assert run(twins, [{"name": "X", "difficulty": "easy", "osm_ids": ["way/3"]}])[0][0]["id"] == "r-s03"
# 앱에 보일 이름: 난이도 표기만 빼고 다른 괄호는 둔다
for raw, want in {"파노라마(초.중.급)": "파노라마", "델타 D1 (초급)": "델타 D1", "에코 E3 (최상급)": "에코 E3",
                  "중급(우라누스)": "우라누스", "익스트림파크(보드파크)": "익스트림파크(보드파크)", "메인": "메인"}.items():
    assert shown_name({"name": raw}) == want, (raw, shown_name({"name": raw}))
print("ok")
