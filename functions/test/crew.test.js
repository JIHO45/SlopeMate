// 크루 함수 (R14): 함수 에뮬레이터로 로그인 토큰을 붙여 호출한다.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { call, callRetry, clear, db, newUser, snapshot } from "./helpers.js";

beforeEach(clear);

async function crewWith(owner, n = 0) {
  const { result } = await call("createCrew", { name: "주말반" }, owner);
  const members = [];
  for (let i = 0; i < n; i++) {
    const m = await newUser(`크루원${i}`);
    assert.ok((await call("joinCrew", { token: result.token }, m)).result);
    members.push(m);
  }
  return { ...result, members };
}

test("만들기: 크루장 1명, 초대 하나", async () => {
  const owner = await newUser("지호");
  const { result } = await call("createCrew", { name: "  주말반 " }, owner);
  const s = await snapshot(result.crewId);
  assert.equal(s.crew.name, "주말반");
  assert.equal(s.crew.owner_uid, owner.uid);
  assert.equal(s.crew.member_count, 1);
  assert.deepEqual(s.members, [owner.uid]);
  assert.equal(s.invites, 1);
  const me = await db.doc(`crews/${result.crewId}/members/${owner.uid}`).get();
  assert.equal(me.get("uid"), owner.uid);
  assert.equal(me.get("display_name"), "지호");
});

test("만들기 거부: 로그인 없음, 계정 문서 없음, 만 14세 확인 없음, 삭제 중, 이름 형식", async () => {
  assert.equal((await call("createCrew", { name: "a" })).error.status, "UNAUTHENTICATED");
  for (const u of [await newUser("x", false), await newUser("x", { age14_confirmed: false }), await newUser("x", { deleting: true })]) {
    assert.equal((await call("createCrew", { name: "a" }, u)).error.status, "PERMISSION_DENIED");
  }
  const ok = await newUser();
  for (const name of ["", "   ", "가".repeat(21), 3]) {
    assert.equal((await call("createCrew", { name }, ok)).error.status, "INVALID_ARGUMENT");
  }
  assert.equal((await db.collection("crews").get()).size, 0);
});

test("크루장인 크루 5개 상한: 동시에 만들어도 5개", async () => {
  const owner = await newUser();
  const rs = await Promise.all(Array.from({ length: 8 }, () => callRetry("createCrew", { name: "반" }, owner)));
  assert.equal(rs.filter((r) => r.result).length, 5);
  assert.ok(rs.filter((r) => !r.result).every((r) => r.error.status === "RESOURCE_EXHAUSTED"));
  assert.equal((await db.collection("crews").where("owner_uid", "==", owner.uid).get()).size, 5);
});

test("승계는 상한과 무관: 크루장인 크루가 5개여도 넘겨받고, 그동안 새로 만들 수 없음", async () => {
  const a = await newUser("A");
  const b = await newUser("B");
  for (let i = 0; i < 5; i++) await call("createCrew", { name: `B${i}` }, b);
  const crew = await crewWith(a);
  await call("joinCrew", { token: crew.token }, b);
  assert.ok((await call("leaveCrew", { crewId: crew.crewId }, a)).result);
  assert.equal((await snapshot(crew.crewId)).crew.owner_uid, b.uid);
  assert.equal((await db.collection("crews").where("owner_uid", "==", b.uid).get()).size, 6);
  assert.equal((await call("createCrew", { name: "더" }, b)).error.status, "RESOURCE_EXHAUSTED");
});

// 에뮬레이터는 한 문서에 몰린 트랜잭션을 운영보다 훨씬 자주 중단(ABORTED)시켜 50명 동시 호출은 재시도만 반복한다.
// 그래서 47명을 채운 뒤 6명이 동시에 정원 경계를 다투게 한다. 50명 동시 가입은 운영에서 따로 확인(todo).
test("정원 경계 동시 가입: 47명인 크루에 6명 → 3명 성공·3명 정원 초과, 인원과 문서 수 일치", async () => {
  const owner = await newUser();
  const crew = await crewWith(owner);
  const batch = db.batch();
  for (let i = 0; i < 46; i++) batch.set(db.doc(`crews/${crew.crewId}/members/seed${i}`), { uid: `seed${i}`, joined_at: new Date() });
  batch.update(db.doc(`crews/${crew.crewId}`), { member_count: 47 });
  await batch.commit();
  const users = await Promise.all(Array.from({ length: 6 }, (_, i) => newUser(`u${i}`)));
  const rs = await Promise.all(users.map((u) => callRetry("joinCrew", { token: crew.token }, u)));
  assert.equal(rs.filter((r) => r.result).length, 3);
  assert.deepEqual(rs.filter((r) => !r.result).map((r) => r.error.status), Array(3).fill("RESOURCE_EXHAUSTED"));
  const s = await snapshot(crew.crewId);
  assert.equal(s.crew.member_count, 50);
  assert.equal(s.members.length, 50);
  assert.equal((await call("previewInvite", { token: crew.token })).result.full, true);
});

test("같은 사람이 동시에 두 번 가입해도 1명", async () => {
  const crew = await crewWith(await newUser());
  const u = await newUser();
  const rs = await Promise.all([1, 2, 3].map(() => callRetry("joinCrew", { token: crew.token }, u)));
  assert.ok(rs.every((r) => r.result?.crewId === crew.crewId));
  const s = await snapshot(crew.crewId);
  assert.equal(s.crew.member_count, 2);
  assert.equal(s.members.length, 2);
});

test("미리보기: 로그인 없이 이름·인원, 로그인하면 이미 멤버인지도. 없는 링크는 not-found", async () => {
  const owner = await newUser();
  const crew = await crewWith(owner, 2);
  const anon = await call("previewInvite", { token: crew.token });
  assert.deepEqual(anon.result, { name: "주말반", member_count: 3, full: false, owner_name: "스키어" });
  assert.equal((await call("previewInvite", { token: crew.token }, owner)).result.already_member, true);
  for (const token of ["A".repeat(22), "bad", "../x"]) {
    assert.equal((await call("previewInvite", { token })).error.status, "NOT_FOUND");
  }
});

test("크루장이 나가면 가장 먼저 가입한 다음 사람이 크루장", async () => {
  const owner = await newUser();
  const crew = await crewWith(owner, 3);
  await call("leaveCrew", { crewId: crew.crewId }, owner);
  const s = await snapshot(crew.crewId);
  assert.equal(s.crew.owner_uid, crew.members[0].uid);
  assert.equal(s.crew.member_count, 3);
  assert.ok(!s.members.includes(owner.uid));
  // 다시 나가도 그대로 성공
  assert.ok((await call("leaveCrew", { crewId: crew.crewId }, owner)).result.left);
  assert.equal((await snapshot(crew.crewId)).crew.member_count, 3);
});

test("링크를 여러 번 바꾼 뒤 마지막 사람이 나가면 크루·멤버·초대가 모두 사라짐", async () => {
  const owner = await newUser();
  const crew = await crewWith(owner, 2);
  await call("kickMember", { crewId: crew.crewId, uid: crew.members[1].uid }, owner);
  let token = crew.token;
  for (let i = 0; i < 3; i++) token = (await call("rotateInvite", { crewId: crew.crewId }, owner)).result.token;
  assert.equal((await call("joinCrew", { token: crew.token }, await newUser())).error.status, "NOT_FOUND");
  assert.equal((await snapshot(crew.crewId)).invites, 1);
  await call("leaveCrew", { crewId: crew.crewId }, crew.members[0]);
  await call("leaveCrew", { crewId: crew.crewId }, owner);
  const s = await snapshot(crew.crewId);
  assert.equal(s.crew, null);
  assert.equal(s.members.length, 0);
  assert.equal((await db.collection(`crews/${crew.crewId}/bans`).get()).size, 0);
  assert.equal((await db.collection("invites").get()).size, 0);
  assert.equal((await call("previewInvite", { token })).error.status, "NOT_FOUND");
});

test("크루장만: 내보내기·이름 바꾸기·링크 교체. 거부되면 데이터 그대로", async () => {
  const owner = await newUser();
  const crew = await crewWith(owner, 2);
  const [m1, m2] = crew.members;
  const outsider = await newUser();
  const before = await snapshot(crew.crewId);
  for (const who of [m1, outsider]) {
    assert.equal((await call("kickMember", { crewId: crew.crewId, uid: m2.uid }, who)).error.status, "PERMISSION_DENIED");
    assert.equal((await call("renameCrew", { crewId: crew.crewId, name: "새" }, who)).error.status, "PERMISSION_DENIED");
    assert.equal((await call("rotateInvite", { crewId: crew.crewId }, who)).error.status, "PERMISSION_DENIED");
  }
  assert.equal((await call("kickMember", { crewId: crew.crewId, uid: owner.uid }, owner)).error.status, "INVALID_ARGUMENT");
  await db.doc(`users/${owner.uid}`).update({ deleting: true });
  assert.equal((await call("kickMember", { crewId: crew.crewId, uid: m2.uid }, owner)).error.status, "PERMISSION_DENIED");
  assert.deepEqual(await snapshot(crew.crewId), before);
  await db.doc(`users/${owner.uid}`).update({ deleting: false });

  assert.ok((await call("kickMember", { crewId: crew.crewId, uid: m2.uid }, owner)).result.kicked);
  // 내보낸 사람은 같은 링크로도, 새 링크로도 못 들어오고, 크루장이 풀면 들어온다
  assert.equal((await call("joinCrew", { token: crew.token }, m2)).error.status, "PERMISSION_DENIED");
  const fresh = (await call("rotateInvite", { crewId: crew.crewId }, owner)).result.token;
  assert.equal((await call("joinCrew", { token: fresh }, m2)).error.status, "PERMISSION_DENIED");
  assert.equal((await call("unbanMember", { crewId: crew.crewId, uid: m2.uid }, m1)).error.status, "PERMISSION_DENIED");
  assert.ok((await call("unbanMember", { crewId: crew.crewId, uid: m2.uid }, owner)).result.unbanned);
  assert.ok((await call("joinCrew", { token: fresh }, m2)).result);
  assert.ok((await call("kickMember", { crewId: crew.crewId, uid: m2.uid }, owner)).result.kicked);
  assert.equal((await db.doc(`crews/${crew.crewId}`).get()).get("banned"), undefined);
  assert.ok((await call("renameCrew", { crewId: crew.crewId, name: "평일반" }, owner)).result);
  const s = await snapshot(crew.crewId);
  assert.equal(s.crew.name, "평일반");
  assert.equal(s.crew.member_count, 2);
  assert.ok(!s.members.includes(m2.uid));
});

test("삭제 중이 된 계정은 가입·만들기를 못 하고, 나가기는 할 수 있음", async () => {
  const owner = await newUser();
  const crew = await crewWith(owner, 1);
  const u = await newUser();
  await db.doc(`users/${u.uid}`).update({ deleting: true });
  assert.equal((await call("joinCrew", { token: crew.token }, u)).error.status, "PERMISSION_DENIED");
  assert.equal((await call("createCrew", { name: "a" }, u)).error.status, "PERMISSION_DENIED");
  assert.equal((await db.doc(`crews/${crew.crewId}/members/${u.uid}`).get()).exists, false);
  const m = crew.members[0];
  await db.doc(`users/${m.uid}`).delete();
  assert.ok((await call("leaveCrew", { crewId: crew.crewId }, m)).result.left);
  assert.equal((await snapshot(crew.crewId)).crew.member_count, 1);
});

test("표시 이름 바꾸기: users와 속한 모든 크루의 멤버 문서", async () => {
  const u = await newUser("지호");
  const c1 = await crewWith(u);
  const c2 = await crewWith(await newUser());
  await call("joinCrew", { token: c2.token }, u);
  const r = await call("setDisplayName", { name: "JH" }, u);
  assert.equal(r.result.crews, 2);
  assert.equal((await db.doc(`users/${u.uid}`).get()).get("display_name"), "JH");
  for (const c of [c1, c2]) assert.equal((await db.doc(`crews/${c.crewId}/members/${u.uid}`).get()).get("display_name"), "JH");
  assert.equal((await call("setDisplayName", { name: "가".repeat(21) }, u)).error.status, "INVALID_ARGUMENT");
});

test("삭제 시작과 가입이 겹쳐도 삭제 중이 된 뒤에는 멤버가 생기지 않음", async () => {
  const crew = await crewWith(await newUser());
  for (let i = 0; i < 10; i++) {
    const u = await newUser();
    const [r] = await Promise.all([
      callRetry("joinCrew", { token: crew.token }, u),
      db.doc(`users/${u.uid}`).update({ deleting: true }),
    ]);
    const joined = (await db.doc(`crews/${crew.crewId}/members/${u.uid}`).get()).exists;
    assert.equal(joined, Boolean(r.result), "성공 응답과 멤버 문서가 일치");
    if (joined) {
      // 가입이 먼저 끝났다: 그 뒤의 삭제 함수(R13 단계)가 지운다. 여기서는 삭제 중 상태에서 추가 가입이 안 되는지만 본다.
      assert.equal((await call("joinCrew", { token: crew.token }, u)).result?.crewId, crew.crewId);
    }
  }
  const s = await snapshot(crew.crewId);
  assert.equal(s.crew.member_count, s.members.length);
});
