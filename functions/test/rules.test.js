// 보안 규칙 (R14, R15): 같은 크루 멤버만 읽고, 클라이언트는 쓰지 못한다.
import { test, before, after, beforeEach } from "node:test";
import { readFileSync } from "node:fs";
import { assertFails, assertSucceeds, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { collection, collectionGroup, doc, getDoc, getDocs, query, setDoc, updateDoc, where } from "firebase/firestore";

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
