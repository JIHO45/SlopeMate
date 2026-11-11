// 금지어·가입·신고·처리 (R16): 이름 거르기, signUp, reportName, 계정 삭제 연동, 처리 스크립트 로직.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { call, clear, db, newUser, PROJECT, snapshot } from "./helpers.js";
import { isBannedName, normalizeName } from "../lib/banned.js";
import * as m from "../lib/moderation.js";

beforeEach(clear);

test("금지어: 띄어쓰기·숫자·자모·폭 없는 문자·전각 우회도 거르고, 정상 이름은 통과", () => {
  for (const s of ["시 1 발", "시ㅂㅏㄹ", "시바ㄹ", "시​발", "ＳＨＩＴ", "병 신", "ㅅㅂ", "ㅅ ㅂ", "관리자", "관리자1", "운영자 ", "슬로프메이트 공식", "SlopeMate Team"]) {
    assert.ok(isBannedName(s), s);
  }
  for (const s of ["주말반", "하이원 보더", "조조", "갓바위", "닭이", "달기", "곤지암", "비관리자", "slopemate팬", "나는 관리자", "Jiho", "스키어"]) {
    assert.ok(!isBannedName(s), s);
  }
  // 완성형과 호환·조합 자모가 같은 형태가 된다
  assert.equal(normalizeName("ㅂㅏㄹ"), "발");
  assert.equal(normalizeName("발"), "발");
  assert.equal(normalizeName("닭이"), "닭이");
});

test("금지어 거부: 크루 만들기·이름 바꾸기·표시 이름·가입·이름 확인", async () => {
  const me = await newUser("지호");
  const crew = (await call("createCrew", { name: "주말반" }, me)).result;
  for (const [fn, data] of [["createCrew", { name: "시 발" }], ["renameCrew", { crewId: crew.crewId, name: "병신들" }],
    ["setDisplayName", { name: "관리자" }], ["checkName", { name: "ㅅㅂ" }]]) {
    const r = await call(fn, data, fn === "checkName" ? undefined : me);
    assert.equal(r.error?.status, "INVALID_ARGUMENT", fn);
    assert.equal(r.error?.message, "banned", fn);
  }
  assert.deepEqual((await call("checkName", { name: "주말반" })).result, { ok: true });
  const fresh = await newUser("x", false);
  assert.equal((await call("signUp", { name: "씨 빨", age14Confirmed: true }, fresh)).error.message, "banned");
  assert.equal((await db.doc(`users/${fresh.uid}`).get()).exists, false);
});

test("가입: 만들기, 다시 로그인하면 이름만 바꿈(크루에도), 만 14세 확인 필요, 동시 호출", async () => {
  const me = await newUser("x", false);
  assert.equal((await call("signUp", { name: "지호" }, me)).error.message, "age");
  const rs = await Promise.all([1, 2].map(() => call("signUp", { name: "지호", age14Confirmed: true }, me)));
  for (const r of rs) assert.ok(r.result, JSON.stringify(r));
  const u = await db.doc(`users/${me.uid}`).get();
  assert.equal(u.get("display_name"), "지호");
  assert.equal(u.get("age14_confirmed"), true);
  assert.equal(u.get("deleting"), false);
  const crew = (await call("createCrew", { name: "주말반" }, me)).result;
  assert.deepEqual((await call("signUp", { name: "JH", age14Confirmed: true }, me)).result, { existing: true, restricted: false });
  assert.equal((await db.doc(`crews/${crew.crewId}/members/${me.uid}`).get()).get("display_name"), "JH");
});

test("가입 거부: 삭제 중·삭제를 끝낸 계정. 이용 제한은 다시 가입해도 풀리지 않고 이름도 그대로", async () => {
  const deleting = await newUser("x", { deleting: true });
  assert.equal((await call("signUp", { name: "지호", age14Confirmed: true }, deleting)).error.status, "PERMISSION_DENIED");
  assert.equal((await db.doc(`users/${deleting.uid}`).get()).get("deleting"), true);
  const gone = await newUser("x", false);
  await db.doc(`deleted_users/${gone.uid}`).set({ at: new Date() });
  assert.equal((await call("signUp", { name: "지호", age14Confirmed: true }, gone)).error.status, "PERMISSION_DENIED");
  assert.equal((await db.doc(`users/${gone.uid}`).get()).exists, false);

  const bad = await newUser("나쁜이름");
  await m.restrict(db, bad.uid);
  assert.deepEqual((await call("signUp", { name: "새이름", age14Confirmed: true }, bad)).result, { existing: true, restricted: true });
  const u = await db.doc(`users/${bad.uid}`).get();
  assert.equal(u.get("restricted"), true);
  assert.equal(u.get("display_name"), "나쁜이름");
  for (const [fn, data] of [["createCrew", { name: "a" }], ["setDisplayName", { name: "b" }]]) {
    assert.equal((await call(fn, data, bad)).error.message, "restricted", fn);
  }
});

async function crewOf(n) {
  const owner = await newUser("크루장");
  const c = (await call("createCrew", { name: "주말반" }, owner)).result;
  const members = [];
  for (let i = 0; i < n; i++) {
    const u = await newUser(`크루원${i}`);
    await call("joinCrew", { token: c.token }, u);
    members.push(u);
  }
  return { owner, crewId: c.crewId, token: c.token, members };
}
const reportsOf = async () => (await db.collection("reports").get()).docs.map((d) => d.data());
const pause = () => db.collection("users").get().then((s) => Promise.all(s.docs.map((d) => d.ref.update({ last_report_call: new Date(0) }))));

test("신고: 크루 이름·표시 이름, 당시 이름 복사, 같은 신고는 하나, 이름이 바뀌면 새 신고, 대상이 다르면 따로", async () => {
  const { owner, crewId, members: [a, b, c] } = await crewOf(3);
  await db.doc(`crews/${crewId}/members/${c.uid}`).update({ display_name: "크루원1" });  // b와 같은 이름
  assert.deepEqual((await call("reportName", { crewId, target: "crew_name" }, a)).result, { reported: true });
  await pause();
  await call("reportName", { crewId, target: "display_name", targetUid: b.uid }, a);
  await pause();
  await call("reportName", { crewId, target: "display_name", targetUid: b.uid }, a);  // 같은 신고
  await pause();
  await call("reportName", { crewId, target: "display_name", targetUid: c.uid }, a);  // 같은 이름, 다른 사람
  let rs = await reportsOf();
  assert.equal(rs.length, 3);
  const crewReport = rs.find((r) => r.target === "crew_name");
  assert.equal(crewReport.name, "주말반");
  assert.equal(crewReport.target_uid, owner.uid);
  assert.ok(rs.every((r) => r.reporter_uid === a.uid && r.status === "open" && r.expire_at));
  // 이름이 바뀌면 새 신고
  await pause();
  await call("setDisplayName", { name: "바뀐이름" }, b);
  await call("reportName", { crewId, target: "display_name", targetUid: b.uid }, a);
  rs = await reportsOf();
  assert.equal(rs.length, 4);
  assert.ok(rs.some((r) => r.name === "바뀐이름"));
  // 문서 ID에는 uid가 없다
  for (const d of (await db.collection("reports").get()).docs) assert.ok(![a.uid, b.uid, c.uid, owner.uid].some((u) => d.id.includes(u)));
});

test("신고 거부: 비멤버, 자기 자신, 대상이 멤버 아님·삭제 중, 5초 간격, 하루 10건", async () => {
  const { crewId, members: [a, b] } = await crewOf(2);
  const outsider = await newUser("밖");
  assert.equal((await call("reportName", { crewId, target: "crew_name" }, outsider)).error.status, "PERMISSION_DENIED");
  assert.equal((await call("reportName", { crewId, target: "display_name", targetUid: a.uid }, a)).error.message, "self");
  assert.equal((await call("reportName", { crewId, target: "display_name", targetUid: outsider.uid }, a)).error.status, "NOT_FOUND");
  await db.doc(`users/${b.uid}`).update({ deleting: true });
  assert.equal((await call("reportName", { crewId, target: "display_name", targetUid: b.uid }, a)).error.status, "NOT_FOUND");
  await pause();
  assert.ok((await call("reportName", { crewId, target: "crew_name" }, a)).result);
  assert.equal((await call("reportName", { crewId, target: "crew_name" }, a)).error.message, "slow-down");
  // 하루 10건
  await db.doc(`users/${a.uid}`).update({ report_day: new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10), report_count: 10, last_report_call: new Date(0) });
  await db.doc(`crews/${crewId}`).update({ name: "새이름" });
  assert.equal((await call("reportName", { crewId, target: "crew_name" }, a)).error.message, "daily-limit");
});

test("계정 삭제: 내가 낸 신고는 신고자 정보만 지우고, 나에 대한 신고는 지운다", async () => {
  const { crewId, members: [a, b] } = await crewOf(2);
  await call("reportName", { crewId, target: "display_name", targetUid: b.uid }, a);
  await pause();
  await call("reportName", { crewId, target: "display_name", targetUid: a.uid }, b);
  assert.deepEqual((await call("deleteAccount", {}, a)).result, { deleted: true });
  const rs = await reportsOf();
  assert.equal(rs.length, 1);
  assert.equal(rs[0].target_uid, b.uid);
  assert.equal(rs[0].reporter_uid, undefined);
  assert.equal(rs[0].key, undefined);
});

test("처리: 표시 이름 초기화는 당시 이름인 사본만(차단 기록 포함), 크루 이름·닫기·조치 없음, 같은 신고 묶어 닫기", async () => {
  const { owner, crewId, token, members: [a, b, c] } = await crewOf(3);
  await call("reportName", { crewId, target: "display_name", targetUid: b.uid }, a);
  await call("reportName", { crewId, target: "display_name", targetUid: b.uid }, c);
  await call("kickMember", { crewId, uid: b.uid }, owner);  // 차단 기록에 이름 사본
  const groups = await m.listOpen(db);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].ids.length, 2);
  const first = await m.resetName(db, groups[0].ids[0]);
  assert.equal(first.status, "resolved");
  assert.ok(first.changed >= 2);
  // 같은 명령을 다시 실행해도 결과가 뒤집히지 않는다
  assert.deepEqual(await m.resetName(db, groups[0].ids[0]), { status: "resolved", already: true, changed: 0 });
  assert.deepEqual(await m.dismiss(db, groups[0].ids[1]), { status: "resolved", already: true, changed: 0 });
  assert.equal((await db.doc(`users/${b.uid}`).get()).get("display_name"), m.RESET_NAME);
  assert.equal((await db.doc(`crews/${crewId}/bans/${b.uid}`).get()).get("display_name"), m.RESET_NAME);
  assert.ok((await reportsOf()).every((r) => r.status === "resolved"));
  // 신고 뒤 스스로 바꾼 이름은 건드리지 않는다
  await pause();
  await call("reportName", { crewId, target: "display_name", targetUid: c.uid }, a);
  await call("setDisplayName", { name: "새이름" }, c);
  const open = await m.listOpen(db);
  assert.deepEqual(await m.resetName(db, open[0].ids[0]), { status: "dismissed", already: false, changed: 0 });
  assert.equal((await db.doc(`users/${c.uid}`).get()).get("display_name"), "새이름");
  // 바꾼 것이 없으면 "검토"로 닫는다
  assert.equal((await db.doc(`reports/${open[0].ids[0]}`).get()).get("status"), "dismissed");
  // 크루 이름: 당시 이름일 때만 바꿈, 닫기
  await pause();
  await call("reportName", { crewId, target: "crew_name" }, a);
  const cr = (await m.listOpen(db))[0].ids[0];
  assert.equal((await m.renameCrew(db, cr, "바뀐 크루")).status, "resolved");
  assert.equal((await m.renameCrew(db, cr, "또 다른 이름")).already, true);
  assert.equal((await db.doc(`crews/${crewId}`).get()).get("name"), "바뀐 크루");
  assert.equal((await db.doc(`reports/${cr}`).get()).get("status"), "resolved");
  // 이미 바뀐 크루 이름의 신고는 검토로 닫힘
  await pause();
  await call("reportName", { crewId, target: "crew_name" }, a);
  const again = (await m.listOpen(db))[0].ids[0];
  await db.doc(`crews/${crewId}`).update({ name: "크루장이 고침" });
  assert.equal((await m.renameCrew(db, again, "다른 이름")).status, "dismissed");
  assert.equal((await db.doc(`crews/${crewId}`).get()).get("name"), "크루장이 고침");
  assert.equal((await db.doc(`reports/${again}`).get()).get("status"), "dismissed");
  // 이미 닫힌 신고로는 크루를 닫지 않는다(아무것도 하지 않음)
  assert.equal((await m.closeCrew(db, cr)).already, true);
  assert.ok((await db.doc(`crews/${crewId}`).get()).exists);
  await pause();
  await call("reportName", { crewId, target: "crew_name" }, a);
  const toClose = (await m.listOpen(db))[0].ids[0];
  assert.equal((await m.closeCrew(db, toClose)).status, "resolved");
  assert.equal((await m.closeCrew(db, toClose)).already, true);
  assert.deepEqual(await snapshot(crewId), { crew: null, members: [], invites: 0 });
  assert.equal((await call("joinCrew", { token }, await newUser("새"))).error.status, "NOT_FOUND");
  // 조치 없음
  const { crewId: c2, members: [x] } = await crewOf(1);
  await call("reportName", { crewId: c2, target: "crew_name" }, x);
  await m.dismiss(db, (await m.listOpen(db))[0].ids[0]);
  assert.ok((await reportsOf()).some((r) => r.status === "dismissed"));
});

test("처리: 신고로 이용 제한하면 계정이 제한되고 신고는 조치로 닫혀 신고자가 읽을 수 있다", async () => {
  const { owner, crewId, members: [a, b] } = await crewOf(2);
  await call("reportName", { crewId, target: "display_name", targetUid: b.uid }, a);
  await pause();
  await call("reportName", { crewId, target: "crew_name" }, a);
  const groups = await m.listOpen(db);
  const member = groups.find((g) => g.target === "display_name").ids[0];
  const crewName = groups.find((g) => g.target === "crew_name").ids[0];
  assert.equal((await m.restrictByReport(db, member)).status, "resolved");
  assert.equal((await m.restrictByReport(db, member)).already, true);
  assert.equal((await db.doc(`users/${b.uid}`).get()).get("restricted"), true);
  assert.equal((await db.doc(`reports/${member}`).get()).get("status"), "resolved");
  // 크루 이름 신고는 크루장을 제한
  assert.equal((await m.restrictByReport(db, crewName)).status, "resolved");
  assert.equal((await db.doc(`users/${owner.uid}`).get()).get("restricted"), true);
  assert.equal((await m.listOpen(db)).length, 0);
  // 삭제 중인 계정이면 제한하지 않고 검토로 닫음
  const { crewId: c2, members: [x, y] } = await crewOf(2);
  await call("reportName", { crewId: c2, target: "display_name", targetUid: y.uid }, x);
  const r = (await m.listOpen(db))[0].ids[0];
  await db.doc(`users/${y.uid}`).update({ deleting: true });
  assert.equal((await m.restrictByReport(db, r)).status, "dismissed");
  // 이름 초기화는 삭제 중인 계정이면 아무것도 하지 않고 신고를 열어 둔다
  await pause();
  const { crewId: c3, members: [p, q] } = await crewOf(2);
  await call("reportName", { crewId: c3, target: "display_name", targetUid: q.uid }, p);
  const open3 = (await m.listOpen(db)).find((g) => g.crew_id === c3).ids[0];
  await db.doc(`users/${q.uid}`).update({ deleting: true });
  assert.equal(await m.resetName(db, open3), null);
  assert.equal((await db.doc(`reports/${open3}`).get()).get("status"), "open");
  assert.equal((await db.doc(`reports/${r}`).get()).get("status"), "dismissed");
});

test("정리: 접수 90일 지난 신고는 상태와 무관하게 지운다", async () => {
  await db.doc("reports/old").set({ status: "open", expire_at: new Date(Date.now() - 1000) });
  await db.doc("reports/new").set({ status: "resolved", expire_at: new Date(Date.now() + 86_400_000) });
  const res = await fetch(`http://127.0.0.1:5001/${PROJECT}/asia-northeast3/sweepDeletions-0`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  assert.equal(res.status, 200);
  assert.equal((await db.doc("reports/old").get()).exists, false);
  assert.ok((await db.doc("reports/new").get()).exists);
});
