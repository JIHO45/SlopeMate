// 크루 함수 (R14, 05-design 6장). 권한 변경은 서버 함수만 하고, 함수는 보안 규칙을 거치지 않으므로 여기서 직접 확인한다.
// 전제 조건(계정, 크루장, 초대, 멤버 여부, 인원)은 바꾸는 트랜잭션 안에서 읽는다.
import { initializeApp } from "firebase-admin/app";
import { DocumentSnapshot, FieldValue, getFirestore, Transaction } from "firebase-admin/firestore";
import { setGlobalOptions } from "firebase-functions/v2";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

initializeApp();
const db = getFirestore();
setGlobalOptions({ region: "asia-northeast3", maxInstances: 10 });

export const MAX_MEMBERS = 50;
/** 새로 만들 때만 세는 상한. 나갈 때 자동 승계로 넘겨받는 것은 막지 않는다(decisions 2026-11-10). */
export const MAX_OWNED = 5;

const crews = db.collection("crews");
const invites = db.collection("invites");

// MARK: 입력 확인

function uidOf(req: CallableRequest): string {
  if (!req.auth) throw new HttpsError("unauthenticated", "login");
  return req.auth.uid;
}

function nameArg(v: unknown): string {
  const t = typeof v === "string" ? v.trim() : "";
  if ([...t].length < 1 || [...t].length > 20) throw new HttpsError("invalid-argument", "name");
  return t;
}

function idArg(v: unknown, field: string): string {
  if (typeof v !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(v)) throw new HttpsError("invalid-argument", field);
  return v;
}

/** 초대 토큰: 128비트 무작위, base64url 22자. 형식이 틀리면 없는 링크와 똑같이 다룬다. */
function tokenArg(v: unknown): string {
  if (typeof v !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(v)) throw new HttpsError("not-found", "invite");
  return v;
}

const newToken = () => randomBytes(16).toString("base64url");

// MARK: 공통

/** 계정 문서가 있고, 만 14세 확인을 했고, 삭제 중이 아니어야 한다(R13, R20). */
async function requireUser(tx: Transaction, uid: string): Promise<DocumentSnapshot> {
  const u = await tx.get(db.doc(`users/${uid}`));
  if (!u.exists || u.get("age14_confirmed") !== true || u.get("deleting") !== false) {
    throw new HttpsError("permission-denied", "account");
  }
  return u;
}

function memberDoc(uid: string, user: DocumentSnapshot) {
  return {
    uid, display_name: user.get("display_name"),
    visit_days: 0, runs: 0, distance_km: 0, resort_days: {}, summary_at: null,
    joined_at: FieldValue.serverTimestamp(),
  };
}

/** 재시도가 다 실패한 경합은 aborted로 돌려준다(그대로 던지면 클라이언트에는 internal). */
async function run<T>(fn: (tx: Transaction) => Promise<T>): Promise<T> {
  try {
    return await db.runTransaction(fn);
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    if ((e as { code?: unknown }).code === 10) throw new HttpsError("aborted", "busy");
    throw e;
  }
}

/** 크루장만 하는 일의 공통 확인 */
async function ownerCrew(tx: Transaction, uid: string, crewId: string): Promise<DocumentSnapshot> {
  await requireUser(tx, uid);
  const crew = await tx.get(crews.doc(crewId));
  if (!crew.exists) throw new HttpsError("not-found", "crew");
  if (crew.get("owner_uid") !== uid) throw new HttpsError("permission-denied", "owner");
  return crew;
}

// MARK: 함수

export const createCrew = onCall(async (req) => {
  const uid = uidOf(req);
  const name = nameArg(req.data?.name);
  return run(async (tx) => {
    const user = await requireUser(tx, uid);
    const owned = await tx.get(crews.where("owner_uid", "==", uid).count());
    if (owned.data().count >= MAX_OWNED) throw new HttpsError("resource-exhausted", "owned-limit");
    const crew = crews.doc();
    const token = newToken();
    tx.set(crew, { name, owner_uid: uid, member_count: 1, invite_token: token, created_at: FieldValue.serverTimestamp() });
    tx.set(crew.collection("members").doc(uid), memberDoc(uid, user));
    tx.set(invites.doc(token), { crew_id: crew.id });
    // 같은 사람의 동시 생성이 서로 부딪혀 하나가 다시 세도록 계정 문서도 쓴다
    tx.update(user.ref, { crews_changed_at: FieldValue.serverTimestamp() });
    return { crewId: crew.id, token };
  });
});

/** 로그인 없이도 부른다(앱 미가입자, 초대 웹페이지). 크루 이름과 인원만 준다. */
export const previewInvite = onCall(async (req) => {
  const token = tokenArg(req.data?.token);
  const inv = await invites.doc(token).get();
  const crew = inv.exists ? await crews.doc(inv.get("crew_id")).get() : undefined;
  if (!crew?.exists) throw new HttpsError("not-found", "invite");
  const count = crew.get("member_count") as number;
  const result: Record<string, unknown> = { name: crew.get("name"), member_count: count, full: count >= MAX_MEMBERS };
  if (req.auth) result.already_member = (await crew.ref.collection("members").doc(req.auth.uid).get()).exists;
  return result;
});

export const joinCrew = onCall(async (req) => {
  const uid = uidOf(req);
  const token = tokenArg(req.data?.token);
  return run(async (tx) => {
    const user = await requireUser(tx, uid);
    const inv = await tx.get(invites.doc(token));
    if (!inv.exists) throw new HttpsError("not-found", "invite");
    const crewRef = crews.doc(inv.get("crew_id"));
    const crew = await tx.get(crewRef);
    const me = await tx.get(crewRef.collection("members").doc(uid));
    if (!crew.exists) throw new HttpsError("not-found", "invite");
    if (me.exists) return { crewId: crewRef.id };
    if (crew.get("member_count") >= MAX_MEMBERS) throw new HttpsError("resource-exhausted", "full");
    tx.set(me.ref, memberDoc(uid, user));
    tx.update(crewRef, { member_count: FieldValue.increment(1) });
    return { crewId: crewRef.id };
  });
});

/** 크루장이 나가면 가장 먼저 가입한 다음 사람이 크루장. 마지막 한 명이면 크루와 초대를 지운다. */
export const leaveCrew = onCall(async (req) => {
  const uid = uidOf(req);
  const crewId = idArg(req.data?.crewId, "crewId");
  return run(async (tx) => {
    await requireUser(tx, uid);
    const crewRef = crews.doc(crewId);
    const crew = await tx.get(crewRef);
    const me = await tx.get(crewRef.collection("members").doc(uid));
    if (!crew.exists || !me.exists) return { left: true };
    if (crew.get("member_count") <= 1) {
      tx.delete(me.ref);
      tx.delete(invites.doc(crew.get("invite_token")));
      tx.delete(crewRef);
      return { left: true, deleted: true };
    }
    let owner = crew.get("owner_uid") as string;
    if (owner === uid) {
      const first = await tx.get(crewRef.collection("members").orderBy("joined_at").limit(2));
      owner = first.docs.map((d) => d.id).find((id) => id !== uid) ?? owner;
    }
    tx.delete(me.ref);
    tx.update(crewRef, { member_count: FieldValue.increment(-1), owner_uid: owner });
    return { left: true };
  });
});

export const kickMember = onCall(async (req) => {
  const uid = uidOf(req);
  const crewId = idArg(req.data?.crewId, "crewId");
  const target = idArg(req.data?.uid, "uid");
  if (target === uid) throw new HttpsError("invalid-argument", "self");
  return run(async (tx) => {
    const crew = await ownerCrew(tx, uid, crewId);
    const member = await tx.get(crew.ref.collection("members").doc(target));
    if (!member.exists) return { kicked: false };
    tx.delete(member.ref);
    tx.update(crew.ref, { member_count: FieldValue.increment(-1) });
    return { kicked: true };
  });
});

export const renameCrew = onCall(async (req) => {
  const uid = uidOf(req);
  const crewId = idArg(req.data?.crewId, "crewId");
  const name = nameArg(req.data?.name);
  return run(async (tx) => {
    const crew = await ownerCrew(tx, uid, crewId);
    tx.update(crew.ref, { name });
    return { name };
  });
});

/** 이전 초대 문서는 지운다. 없는 링크 = "이 초대 링크는 더 이상 쓸 수 없어요". */
export const rotateInvite = onCall(async (req) => {
  const uid = uidOf(req);
  const crewId = idArg(req.data?.crewId, "crewId");
  return run(async (tx) => {
    const crew = await ownerCrew(tx, uid, crewId);
    const token = newToken();
    tx.delete(invites.doc(crew.get("invite_token")));
    tx.set(invites.doc(token), { crew_id: crewId });
    tx.update(crew.ref, { invite_token: token });
    return { token };
  });
});
