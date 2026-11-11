// 보안 규칙 (R14, R15): 같은 크루 멤버만 읽고, 클라이언트는 쓰지 못한다.
import { test, before, after, beforeEach } from "node:test";
import { readFileSync } from "node:fs";
import { assertFails, assertSucceeds, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { collection, collectionGroup, doc, getDoc, getDocs, query, serverTimestamp, setDoc, updateDoc, where } from "firebase/firestore";

let env;
before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-slopemate",
    firestore: { rules: readFileSync(new URL("../../firebase/firestore.rules", import.meta.url), "utf8") },
  });
});
after(() => env.cleanup());
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (c) => {
    const db = c.firestore();
    await setDoc(doc(db, "crews/c1"), { name: "주말반", owner_uid: "a", member_count: 2, invite_token: "t" });
    await setDoc(doc(db, "crews/c1/members/a"), { uid: "a", runs: 3 });
    await setDoc(doc(db, "crews/c1/members/b"), { uid: "b", runs: 5 });
    await setDoc(doc(db, "crews/c2"), { name: "다른반", owner_uid: "z", member_count: 1, invite_token: "u" });
    await setDoc(doc(db, "crews/c2/members/z"), { uid: "z", runs: 9 });
    await setDoc(doc(db, "invites/t"), { crew_id: "c1" });
    await setDoc(doc(db, "crews/c1/bans/x"), { uid: "x", display_name: "누군가" });
    await setDoc(doc(db, "season_summaries/b_2026-27"), { uid: "b", season: "2026-27", runs: 5, computed_at: 1 });
  });
});

const as = (uid) => (uid ? env.authenticatedContext(uid) : env.unauthenticatedContext()).firestore();

test("멤버는 자기 크루와 멤버 목록을 읽는다", async () => {
  await assertSucceeds(getDoc(doc(as("b"), "crews/c1")));
  await assertSucceeds(getDocs(collection(as("b"), "crews/c1/members")));
});

test("다른 크루·로그인 안 함은 읽지 못한다", async () => {
  await assertFails(getDoc(doc(as("b"), "crews/c2")));
  await assertFails(getDocs(collection(as("b"), "crews/c2/members")));
  await assertFails(getDoc(doc(as(null), "crews/c1")));
});

test("나가면(멤버 문서가 지워지면) 바로 못 읽는다", async () => {
  await env.withSecurityRulesDisabled((c) => import("firebase/firestore").then(({ deleteDoc }) => deleteDoc(doc(c.firestore(), "crews/c1/members/b"))));
  await assertFails(getDoc(doc(as("b"), "crews/c1")));
  await assertFails(getDocs(collection(as("b"), "crews/c1/members")));
});

test("내 크루 목록: 내 멤버 문서만 그룹 조회", async () => {
  await assertSucceeds(getDocs(query(collectionGroup(as("b"), "members"), where("uid", "==", "b"))));
  await assertFails(getDocs(query(collectionGroup(as("b"), "members"), where("uid", "==", "z"))));
  await assertFails(getDocs(collectionGroup(as("b"), "members")));
});

test("클라이언트는 크루·멤버·초대를 쓰거나 초대를 읽지 못한다", async () => {
  await assertFails(updateDoc(doc(as("a"), "crews/c1"), { name: "x" }));
  await assertFails(setDoc(doc(as("b"), "crews/c1/members/b"), { uid: "b", runs: 999 }));
  await assertFails(setDoc(doc(as("b"), "crews/c3"), { name: "x", owner_uid: "b" }));
  await assertFails(getDoc(doc(as("b"), "invites/t")));
  await assertFails(setDoc(doc(as("b"), "invites/new"), { crew_id: "c1" }));
});

test("계정 문서: 본인만 읽고, 만들기·바꾸기는 함수만(금지어·만 14세 확인)", async () => {
  const ok = { display_name: "지호", age14_confirmed: true, deleting: false, created_at: serverTimestamp() };
  await assertFails(setDoc(doc(as("n"), "users/n"), ok));
  await env.withSecurityRulesDisabled((c) => setDoc(doc(c.firestore(), "users/n"), { display_name: "지호" }));
  await assertSucceeds(getDoc(doc(as("n"), "users/n")));
  await assertFails(getDoc(doc(as("b"), "users/n")));
  await assertFails(updateDoc(doc(as("n"), "users/n"), { display_name: "JH" }));
});

test("차단 기록: 크루장만 읽고, 크루원·외부인은 못 읽고, 아무도 쓰지 못한다", async () => {
  await assertSucceeds(getDocs(collection(as("a"), "crews/c1/bans")));
  await assertFails(getDocs(collection(as("b"), "crews/c1/bans")));
  await assertFails(getDoc(doc(as("x"), "crews/c1/bans/x")));
  await assertFails(setDoc(doc(as("a"), "crews/c1/bans/y"), { uid: "y" }));
});

test("시즌 합계: 본인만 읽고, 아무도 직접 쓰지 못한다", async () => {
  await assertSucceeds(getDoc(doc(as("b"), "season_summaries/b_2026-27")));
  await assertSucceeds(getDoc(doc(as("n"), "season_summaries/n_2026-27"))); // 아직 없는 본인 문서
  await assertFails(getDoc(doc(as("n"), "season_summaries/b_2026-27")));
  await assertFails(getDoc(doc(as(null), "season_summaries/b_2026-27")));
  await assertFails(getDoc(doc(as("a"), "season_summaries/b_2026-27")));
  await assertFails(setDoc(doc(as("b"), "season_summaries/b_2026-27"), { uid: "b", runs: 999, computed_at: 9 }));
});

test("삭제를 끝낸 계정은 계정 문서를 다시 만들지 못하고, 신고는 신고자만 읽는다", async () => {
  const ok = { display_name: "지호", age14_confirmed: true, deleting: false, created_at: serverTimestamp() };
  await env.withSecurityRulesDisabled((c) => setDoc(doc(c.firestore(), "deleted_users/gone"), { at: new Date() }));
  await assertFails(setDoc(doc(as("gone"), "users/gone"), ok));
  await assertFails(getDoc(doc(as("gone"), "deleted_users/gone")));
  // 신고: 신고한 본인만 읽고 아무도 쓰지 못한다
  await env.withSecurityRulesDisabled((c) => setDoc(doc(c.firestore(), "reports/r1"), { reporter_uid: "b", target_uid: "a", status: "open" }));
  await assertSucceeds(getDoc(doc(as("b"), "reports/r1")));
  await assertSucceeds(getDocs(query(collection(as("b"), "reports"), where("reporter_uid", "==", "b"))));
  await assertFails(getDoc(doc(as("a"), "reports/r1")));
  await assertFails(getDocs(collection(as("b"), "reports")));
  await assertFails(setDoc(doc(as("b"), "reports/r2"), { reporter_uid: "b" }));
  await assertFails(updateDoc(doc(as("b"), "reports/r1"), { status: "resolved" }));
  await assertFails(setDoc(doc(as("n"), "deleted_users/n"), { at: new Date() }));
});
