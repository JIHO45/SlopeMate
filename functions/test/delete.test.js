// 계정 삭제 (R13): 접수 → 정리 → Auth 삭제 → 표시 문서. 중간에 끊긴 상태에서 다시 불러도 끝난다.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { getAuth } from "firebase-admin/auth";
import { call, clear, db, newUser, PROJECT, snapshot } from "./helpers.js";

beforeEach(clear);

const authGone = (uid) => getAuth().getUser(uid).then(() => false, (e) => e.code === "auth/user-not-found");
const season = "2026-27";
const summary = { season, visit_days: 3, runs: 20, distance_km: 31.5, resort_days: { high1: 3 }, computed_at: Date.now() - 1000 };

test("삭제: 계정·합계·크루 소속·차단 기록·Auth 사용자가 모두 지워지고 크루장은 넘어간다", async () => {
  const me = await newUser("지호");
  const a = (await call("createCrew", { name: "넘길 크루" }, me)).result;
  const solo = (await call("createCrew", { name: "혼자" }, me)).result;
  const friend = await newUser("친구");
  await call("joinCrew", { token: a.token }, friend);
  // 다른 크루에서 내보내진 기록
  const other = await newUser("크루장");
  const b = (await call("createCrew", { name: "남의 크루" }, other)).result;
  await call("joinCrew", { token: b.token }, me);
  await call("kickMember", { crewId: b.crewId, uid: me.uid }, other);
  const sync = await call("syncSummary", { ...summary, season: (await db.doc(`crews/${a.crewId}/members/${me.uid}`).get()).get("season") }, me);
  assert.ok(sync.result, JSON.stringify(sync));
  await db.doc(`season_summaries/${me.uid}_2025-26`).set({ uid: me.uid, season: "2025-26" });

  assert.deepEqual((await call("deleteAccount", {}, me)).result, { deleted: true });

  assert.equal((await db.doc(`users/${me.uid}`).get()).exists, false);
  assert.equal((await db.collection("season_summaries").where("uid", "==", me.uid).get()).size, 0);
  assert.equal((await db.collectionGroup("members").where("uid", "==", me.uid).get()).size, 0);
  assert.equal((await db.collectionGroup("bans").where("uid", "==", me.uid).get()).size, 0);
  assert.ok(await authGone(me.uid));
  const s = await snapshot(a.crewId);
  assert.equal(s.crew.owner_uid, friend.uid);
  assert.equal(s.crew.member_count, 1);
  assert.deepEqual(s.members, [friend.uid]);
  assert.deepEqual(await snapshot(solo.crewId), { crew: null, members: [], invites: 0 });
  assert.equal((await snapshot(b.crewId)).crew.member_count, 1);
  assert.ok((await db.doc(`deleted_users/${me.uid}`).get()).exists);
  assert.deepEqual((await call("deletionStatus", { uid: me.uid })).result, { state: "deleted" });
  // 끝난 뒤 남은 토큰으로 다시 불러도 성공이고 users를 다시 만들지 않는다
  assert.deepEqual((await call("deleteAccount", {}, me)).result, { deleted: true });
  assert.equal((await db.doc(`users/${me.uid}`).get()).exists, false);
});

test("삭제 접수 뒤에는 표시 이름이 남지 않고 쓰기가 거부된다", async () => {
  const me = await newUser("지호");
  // 정리 전 상태를 만든다: 접수만 된 계정
  await db.doc(`users/${me.uid}`).set({ deleting: true, delete_requested_at: new Date() });
  for (const [fn, data] of [["createCrew", { name: "a" }], ["syncSummary", summary], ["setDisplayName", { name: "새이름" }]]) {
    assert.equal((await call(fn, data, me)).error.status, "PERMISSION_DENIED", fn);
  }
  assert.deepEqual((await call("deletionStatus", { uid: me.uid })).result, { state: "deleting" });
  assert.deepEqual((await call("deletionStatus", { uid: (await newUser("남")).uid })).result, { state: "active" });
  assert.deepEqual((await call("deletionStatus", { uid: (await newUser("문서 없음", false)).uid })).result, { state: "active" });
});

test("중간에 끊긴 삭제: 일부만 정리된 상태, Auth만 지워진 상태에서 다시 부르면 끝난다", async () => {
  const me = await newUser("지호");
  const a = (await call("createCrew", { name: "하나" }, me)).result;
  const b = (await call("createCrew", { name: "둘" }, me)).result;
  await call("joinCrew", { token: b.token }, await newUser("친구"));
  await db.doc(`users/${me.uid}`).set({ deleting: true });
  await call("leaveCrew", { crewId: a.crewId }, me);
  await getAuth().deleteUser(me.uid);
  // Auth 사용자는 없지만 users 문서가 남아 아직 끝난 것이 아니다
  assert.deepEqual((await call("deletionStatus", { uid: me.uid })).result, { state: "deleting" });

  assert.deepEqual((await call("deleteAccount", {}, me)).result, { deleted: true });
  assert.equal((await db.doc(`users/${me.uid}`).get()).exists, false);
  assert.equal((await db.collectionGroup("members").where("uid", "==", me.uid).get()).size, 0);
  assert.equal((await snapshot(b.crewId)).crew.member_count, 1);
});

test("users 문서가 없는 계정도 지워지고, 동시에 두 번 불러도 둘 다 성공한다", async () => {
  const me = await newUser("x", false);
  const rs = await Promise.all([call("deleteAccount", {}, me), call("deleteAccount", {}, me)]);
  for (const r of rs) assert.deepEqual(r.result, { deleted: true }, JSON.stringify(r));
  assert.ok(await authGone(me.uid));
  assert.equal((await db.doc(`users/${me.uid}`).get()).exists, false);
  assert.equal((await call("deleteAccount", {})).error.status, "UNAUTHENTICATED");
});

test("스케줄 함수: 끊긴 삭제를 마저 하고 하루 지난 표시 문서를 지운다", async () => {
  const me = await newUser("지호");
  const a = (await call("createCrew", { name: "하나" }, me)).result;
  await db.doc(`users/${me.uid}`).set({ deleting: true });
  await db.doc("deleted_users/old").set({ at: new Date(Date.now() - 25 * 3600_000) });
  await db.doc("deleted_users/new").set({ at: new Date() });
  const res = await fetch(`http://127.0.0.1:5001/${PROJECT}/asia-northeast3/sweepDeletions-0`, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  });
  assert.equal(res.status, 200, await res.text());
  assert.equal((await db.doc(`users/${me.uid}`).get()).exists, false);
  assert.ok(await authGone(me.uid));
  assert.equal((await snapshot(a.crewId)).crew, null);
  assert.equal((await db.doc("deleted_users/old").get()).exists, false);
  assert.ok((await db.doc("deleted_users/new").get()).exists);
});
