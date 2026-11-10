// 크루 함수 (R14, 05-design 6장). 권한 변경은 서버 함수만 하고, 함수는 보안 규칙을 거치지 않으므로 여기서 직접 확인한다.
// 전제 조건(계정, 크루장, 초대, 멤버 여부, 인원)은 바꾸는 트랜잭션 안에서 읽는다.
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { DocumentSnapshot, FieldValue, getFirestore, Transaction } from "firebase-admin/firestore";
import { logger, setGlobalOptions } from "firebase-functions/v2";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";
import { currentSeason } from "./season.js";

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

const summaries = db.collection("season_summaries");

/** 크루 순위에 보이는 값: 이번 시즌 합계만(R17). 가입 전 기록도 보인다(S16 안내). */
function summaryFields(sum: DocumentSnapshot | undefined) {
  return sum?.exists
    ? { season: sum.get("season"), visit_days: sum.get("visit_days"), runs: sum.get("runs"), distance_km: sum.get("distance_km"),
        resort_days: sum.get("resort_days"), summary_at: sum.get("updated_at") }
    : { season: currentSeason(), visit_days: 0, runs: 0, distance_km: 0, resort_days: {}, summary_at: null };
}

function memberDoc(uid: string, user: DocumentSnapshot, sum?: DocumentSnapshot) {
  return { uid, display_name: user.get("display_name"), ...summaryFields(sum), joined_at: FieldValue.serverTimestamp() };
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
    const sum = await tx.get(summaries.doc(`${uid}_${currentSeason()}`));
    const owned = await tx.get(crews.where("owner_uid", "==", uid).count());
    if (owned.data().count >= MAX_OWNED) throw new HttpsError("resource-exhausted", "owned-limit");
    const crew = crews.doc();
    const token = newToken();
    tx.set(crew, { name, owner_uid: uid, member_count: 1, invite_token: token, created_at: FieldValue.serverTimestamp() });
    tx.set(crew.collection("members").doc(uid), memberDoc(uid, user, sum));
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
  const owner = await crew.ref.collection("members").doc(crew.get("owner_uid")).get();
  const result: Record<string, unknown> = {
    name: crew.get("name"), member_count: count, full: count >= MAX_MEMBERS, owner_name: owner.get("display_name") ?? "",
  };
  if (req.auth) result.already_member = (await crew.ref.collection("members").doc(req.auth.uid).get()).exists;
  return result;
});

export const joinCrew = onCall(async (req) => {
  const uid = uidOf(req);
  const token = tokenArg(req.data?.token);
  return run(async (tx) => {
    const user = await requireUser(tx, uid);
    const sum = await tx.get(summaries.doc(`${uid}_${currentSeason()}`));
    const inv = await tx.get(invites.doc(token));
    if (!inv.exists) throw new HttpsError("not-found", "invite");
    const crewRef = crews.doc(inv.get("crew_id"));
    const crew = await tx.get(crewRef);
    const me = await tx.get(crewRef.collection("members").doc(uid));
    if (!crew.exists) throw new HttpsError("not-found", "invite");
    const ban = await tx.get(crewRef.collection("bans").doc(uid));
    if (me.exists) return { crewId: crewRef.id };
    // 크루장이 내보낸 사람은 크루장이 차단을 풀기 전까지 새 링크로도 다시 들어오지 못한다(R16)
    if (ban.exists) throw new HttpsError("permission-denied", "kicked");
    if (crew.get("member_count") >= MAX_MEMBERS) throw new HttpsError("resource-exhausted", "full");
    tx.set(me.ref, memberDoc(uid, user, sum));
    tx.update(crewRef, { member_count: FieldValue.increment(1) });
    return { crewId: crewRef.id };
  });
});

/** 크루장이 나가면 가장 먼저 가입한 다음 사람이 크루장. 마지막 한 명이면 크루와 초대를 지운다.
 *  나가기는 계정 상태와 무관하게 로그인만 확인한다(계정 문서가 없어도 나갈 수 있게). */
/** 크루에서 빠진다(나가기, 계정 삭제 공용). 크루장이면 가장 먼저 가입한 사람에게 넘기고, 마지막 멤버면 크루를 지운다. */
async function leaveTx(tx: Transaction, uid: string, crewId: string) {
  const crewRef = crews.doc(crewId);
  const crew = await tx.get(crewRef);
  const me = await tx.get(crewRef.collection("members").doc(uid));
  if (!crew.exists || !me.exists) return { left: true };
  if (crew.get("member_count") <= 1) {
    const bans = await tx.get(crewRef.collection("bans"));
    for (const b of bans.docs) tx.delete(b.ref);
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
}

export const leaveCrew = onCall(async (req) => {
  const uid = uidOf(req);
  const crewId = idArg(req.data?.crewId, "crewId");
  return run((tx) => leaveTx(tx, uid, crewId));
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
    // 차단 기록은 크루원에게 보이지 않는 bans에 둔다(크루장만 읽음, 해제할 때 이름을 보여 주려고 이름도)
    tx.set(crew.ref.collection("bans").doc(target), { uid: target, display_name: member.get("display_name") ?? "", at: FieldValue.serverTimestamp() });
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

/** 표시 이름 바꾸기: users와 내가 속한 모든 크루의 멤버 문서를 함께 바꾼다. */
export const setDisplayName = onCall(async (req) => {
  const uid = uidOf(req);
  const name = nameArg(req.data?.name);
  return run(async (tx) => {
    const user = await requireUser(tx, uid);
    const mine = await tx.get(db.collectionGroup("members").where("uid", "==", uid));
    tx.update(user.ref, { display_name: name });
    for (const m of mine.docs) tx.update(m.ref, { display_name: name });
    return { name, crews: mine.size };
  });
});

/** 차단 해제(크루장). 해제하면 초대 링크로 다시 참여할 수 있다. */
export const unbanMember = onCall(async (req) => {
  const uid = uidOf(req);
  const crewId = idArg(req.data?.crewId, "crewId");
  const target = idArg(req.data?.uid, "uid");
  return run(async (tx) => {
    const crew = await ownerCrew(tx, uid, crewId);
    tx.delete(crew.ref.collection("bans").doc(target));
    return { unbanned: true };
  });
});

// MARK: 시즌 합계 (R15, R17)

function intArg(v: unknown, max: number, field: string): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > max) throw new HttpsError("invalid-argument", field);
  return v;
}

/** 이번 시즌 합계 하나를 받는다. 기기에서 계산한 시각(computed_at)이 저장된 값보다 늦을 때만 바꾸고(R15),
 *  내가 속한 모든 크루의 멤버 문서에 같은 값을 복사한다. 받는 필드는 합계와 리조트별 방문일뿐이다(R17). */
export const syncSummary = onCall(async (req) => {
  const uid = uidOf(req);
  const d = req.data ?? {};
  const allowed = ["season", "visit_days", "runs", "distance_km", "resort_days", "computed_at"];
  if (typeof d !== "object" || Object.keys(d).some((k) => !allowed.includes(k))) throw new HttpsError("invalid-argument", "fields");
  const season = currentSeason();
  if (d.season !== season) throw new HttpsError("failed-precondition", "season");
  const visitDays = intArg(d.visit_days, 200, "visit_days");
  const runs = intArg(d.runs, 100_000, "runs");
  if (typeof d.distance_km !== "number" || !(d.distance_km >= 0) || d.distance_km > 100_000) throw new HttpsError("invalid-argument", "distance_km");
  const distanceKm = Math.round(d.distance_km * 10) / 10;
  const rd = d.resort_days;
  if (typeof rd !== "object" || rd === null || Array.isArray(rd) || Object.keys(rd).length > 40) throw new HttpsError("invalid-argument", "resort_days");
  const resortDays: Record<string, number> = {};
  for (const [k, v] of Object.entries(rd)) {
    if (!/^[a-z0-9_-]{1,40}$/.test(k)) throw new HttpsError("invalid-argument", "resort_days");
    resortDays[k] = intArg(v, 200, "resort_days");
  }
  const computedAt = intArg(d.computed_at, Number.MAX_SAFE_INTEGER, "computed_at");
  if (computedAt > Date.now() + 5 * 60_000) throw new HttpsError("invalid-argument", "computed_at");

  return run(async (tx) => {
    await requireUser(tx, uid);
    const ref = summaries.doc(`${uid}_${season}`);
    const old = await tx.get(ref);
    const mine = await tx.get(db.collectionGroup("members").where("uid", "==", uid));
    // 늦게 도착한 오래된 합계는 버린다(같은 값을 여러 번 보내도 바뀌지 않음)
    if (old.exists && (old.get("computed_at") as number) >= computedAt) return { applied: false, crews: mine.size };
    const values = { visit_days: visitDays, runs, distance_km: distanceKm, resort_days: resortDays };
    tx.set(ref, { uid, season, ...values, computed_at: computedAt, updated_at: FieldValue.serverTimestamp() });
    for (const m of mine.docs) tx.update(m.ref, { season, ...values, summary_at: FieldValue.serverTimestamp() });
    return { applied: true, crews: mine.size };
  });
});

// MARK: 계정 삭제 (R13, 05-design 6장)

/** 처음 삭제를 접수할 때 요구하는 재인증 기한(초). 앱은 Apple 재로그인 직후에 부른다. */
const REAUTH_SECONDS = 600;
/** 삭제를 끝낸 uid 표시. 지워진 계정의 남은 로그인 토큰(최대 1시간)이 users를 다시 만들지 못하게 규칙이 본다. */
const tombstones = db.collection("deleted_users");

/** 삭제를 접수하고 끝까지 지운다. 접수(deleting=true)는 한 번만 재인증을 요구하고, 그 뒤 재호출은 이어서 정리한다.
 *  접수할 때 users 문서를 표시만 남기고 덮어써서 표시 이름 등은 바로 사라진다. 문서가 없던 계정도 표시가 생긴다. */
export const deleteAccount = onCall(async (req) => {
  const uid = uidOf(req);
  const authTime = Number(req.auth?.token.auth_time);
  const done = await run(async (tx) => {
    const ref = db.doc(`users/${uid}`);
    const user = await tx.get(ref);
    const tomb = await tx.get(tombstones.doc(uid));
    if (!user.exists && tomb.exists) return true;
    if (user.get("deleting") !== true) {
      if (!(Date.now() / 1000 - authTime <= REAUTH_SECONDS)) throw new HttpsError("failed-precondition", "reauth");
      tx.set(ref, { deleting: true, delete_requested_at: FieldValue.serverTimestamp() });
    }
    return false;
  });
  if (!done) await purgeUser(uid);
  return { deleted: true };
});

/** 접수된 계정의 서버 데이터를 모두 지운다. 단계마다 이미 없으면 지나가므로 여러 번, 동시에 불러도 된다.
 *  Auth 사용자를 지운 뒤에도 users(deleting=true)가 남아 있는 동안은 requireUser와 create 규칙이, 그 뒤로는 표시 문서가 막는다. */
async function purgeUser(uid: string) {
  const mine = await db.collectionGroup("members").where("uid", "==", uid).get();
  for (const m of mine.docs) {
    const crewId = m.ref.parent.parent?.id;
    if (crewId) await run((tx) => leaveTx(tx, uid, crewId));
  }
  // 크루에서 빠진 뒤에는 새 차단 기록이 생기지 않는다(내보내기는 멤버일 때만)
  const sums = await summaries.where("uid", "==", uid).get();
  const bans = await db.collectionGroup("bans").where("uid", "==", uid).get();
  // ponytail: 한 배치(500개)로 지운다. 한 사람이 500개 크루에서 차단될 일은 없다
  const batch = db.batch();
  for (const d of [...sums.docs, ...bans.docs]) batch.delete(d.ref);
  await batch.commit();
  try {
    await getAuth().deleteUser(uid);
  } catch (e) {
    if ((e as { code?: unknown }).code !== "auth/user-not-found") throw e;
  }
  const end = db.batch();
  end.delete(db.doc(`users/${uid}`));
  end.set(tombstones.doc(uid), { at: FieldValue.serverTimestamp() });
  await end.commit();
}

/** 삭제가 어디까지 갔는지(로그인 없이). 앱이 성공 응답을 받지 못했을 때 확인한다. uid는 추측할 수 없는 값이고 답은 상태 하나뿐이다.
 *  deleted: 계정 문서와 Auth 사용자가 모두 없음. deleting: 접수됨(스케줄 함수가 마저 지움). active: 접수되지 않음. */
export const deletionStatus = onCall(async (req) => {
  const uid = idArg(req.data?.uid, "uid");
  const user = await db.doc(`users/${uid}`).get();
  if (user.exists) return { state: user.get("deleting") === true ? "deleting" : "active" };
  try {
    await getAuth().getUser(uid);
    return { state: "active" };
  } catch (e) {
    if ((e as { code?: unknown }).code !== "auth/user-not-found") throw e;
    return { state: "deleted" };
  }
});

/** 중간에 끊긴 삭제를 마저 한다. 계정 하나가 실패해도 나머지는 계속하고, 세 번 넘게 실패하면 오류로 남긴다. */
export const sweepDeletions = onSchedule("every 60 minutes", async () => {
  const pending = await db.collection("users").where("deleting", "==", true).get();
  for (const u of pending.docs) {
    try {
      await purgeUser(u.id);
    } catch (e) {
      const attempts = ((u.get("delete_attempts") as number | undefined) ?? 0) + 1;
      await u.ref.update({ delete_attempts: attempts }).catch(() => undefined);
      (attempts >= 3 ? logger.error : logger.warn)("account purge failed", { uid: u.id, attempts, error: String(e) });
    }
  }
  const old = await tombstones.where("at", "<", new Date(Date.now() - 24 * 3600_000)).get();
  const batch = db.batch();
  for (const d of old.docs) batch.delete(d.ref);
  await batch.commit();
});
