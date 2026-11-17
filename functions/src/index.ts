// 크루 함수 (R14, 05-design 6장). 권한 변경은 서버 함수만 하고, 함수는 보안 규칙을 거치지 않으므로 여기서 직접 확인한다.
// 전제 조건(계정, 크루장, 초대, 멤버 여부, 인원)은 바꾸는 트랜잭션 안에서 읽는다.
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { DocumentSnapshot, FieldValue, getFirestore, Timestamp, Transaction } from "firebase-admin/firestore";
import { logger, setGlobalOptions } from "firebase-functions/v2";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { createHash, randomBytes } from "node:crypto";
import { isBannedName } from "./banned.js";
import { isClosedTransaction } from "./errors.js";
import { currentSeason } from "./season.js";

initializeApp();
const db = getFirestore();
setGlobalOptions({ region: "asia-northeast3", maxInstances: 10 });

export const MAX_MEMBERS = 50;
/** 새로 만들 때만 세는 상한. 나갈 때 자동 승계로 넘겨받는 것은 막지 않는다(decisions 2026-11-10). */
export const MAX_OWNED = 5;
/** 한 사람이 속할 수 있는 크루 수(만든 것 포함). 합계를 올릴 때마다 속한 크루 수만큼 문서를 쓰므로 상한을 둔다. */
export const MAX_JOINED = 20;

const crews = db.collection("crews");
const invites = db.collection("invites");
const reports = db.collection("reports");
/** 삭제를 끝낸 uid 표시. 지워진 계정의 남은 로그인 토큰(최대 1시간)이 계정을 다시 만들지 못하게 signUp이 본다. */
const tombstones = db.collection("deleted_users");

// MARK: 입력 확인

function uidOf(req: CallableRequest): string {
  if (!req.auth) throw new HttpsError("unauthenticated", "login");
  return req.auth.uid;
}

/** 크루 이름·표시 이름: 앞뒤 공백을 빼고 1~20자, 금지어·사칭이 없어야 한다(R16). */
function nameArg(v: unknown): string {
  const t = typeof v === "string" ? v.trim() : "";
  if ([...t].length < 1 || [...t].length > 20) throw new HttpsError("invalid-argument", "name");
  if (isBannedName(t)) throw new HttpsError("invalid-argument", "banned");
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

/** 계정 문서가 있고, 만 14세 확인을 했고, 삭제 중이 아니어야 한다(R13, R20).
 *  운영자가 이용을 제한한 계정(restricted)도 거부한다(R16). 나가기와 계정 삭제는 이 확인을 거치지 않는다. */
async function requireUser(tx: Transaction, uid: string): Promise<DocumentSnapshot> {
  const u = await tx.get(db.doc(`users/${uid}`));
  if (!u.exists || u.get("age14_confirmed") !== true || u.get("deleting") !== false) {
    throw new HttpsError("permission-denied", "account");
  }
  if (u.get("restricted") === true) throw new HttpsError("permission-denied", "restricted");
  return u;
}

const summaries = db.collection("season_summaries");

/** 크루 순위에 보이는 값: 이번 시즌 합계만(R17). 가입 전 기록도 보인다(S16 안내). */
function summaryFields(sum: DocumentSnapshot | undefined) {
  return sum?.exists
    ? { season: sum.get("season"), visit_days: sum.get("visit_days"), runs: sum.get("runs"), distance_km: sum.get("distance_km"),
        resort_days: sum.get("resort_days") }
    : { season: currentSeason(), visit_days: 0, runs: 0, distance_km: 0, resort_days: {} };
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
    // 경합으로 오래 기다린 쿼리를 SDK가 다시 보낼 때 트랜잭션은 이미 닫혀 있다(커밋되지 않음).
    // INVALID_ARGUMENT로 오지만 입력 문제가 아니라 경합이므로 다시 시도할 수 있게 aborted로 바꾼다.
    if (isClosedTransaction(e)) throw new HttpsError("aborted", "busy");
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
    const joined = await tx.get(db.collectionGroup("members").where("uid", "==", uid).count());
    if (joined.data().count >= MAX_JOINED) throw new HttpsError("resource-exhausted", "joined-limit");
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
  // 로그인했으면 이미 멤버인지와 크루장 uid(기기에서 차단한 사람인지 보려고)도 준다
  if (req.auth) {
    result.already_member = (await crew.ref.collection("members").doc(req.auth.uid).get()).exists;
    result.owner_uid = crew.get("owner_uid");
  }
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
    const joined = await tx.get(db.collectionGroup("members").where("uid", "==", uid).count());
    if (me.exists) return { crewId: crewRef.id };
    // 크루장이 내보낸 사람은 크루장이 차단을 풀기 전까지 새 링크로도 다시 들어오지 못한다(R16)
    if (ban.exists) throw new HttpsError("permission-denied", "kicked");
    if (crew.get("member_count") >= MAX_MEMBERS) throw new HttpsError("resource-exhausted", "full");
    if (joined.data().count >= MAX_JOINED) throw new HttpsError("resource-exhausted", "joined-limit");
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

// MARK: 가입 (R13, R16, R20)

/** 이름을 쓸 수 있는지(로그인 없이). 가입 화면이 Apple 로그인 전에 묻는다. 안내용이고, 저장할 때 다시 검사한다. */
export const checkName = onCall(async (req) => {
  nameArg(req.data?.name);
  return { ok: true };
});

/** 가입: 계정 문서를 만든다. 이미 있으면 표시 이름만 바꾼다(다시 로그인한 경우, 멤버 문서도 함께).
 *  삭제 중이거나 삭제를 끝낸 계정은 거부하고, 운영자가 제한한 계정은 아무것도 바꾸지 않고 restricted로 알린다.
 *  만 14세 확인은 본인 확인 값(age14Confirmed: true)으로 받는다. */
export const signUp = onCall(async (req) => {
  const uid = uidOf(req);
  if (req.data?.age14Confirmed !== true) throw new HttpsError("invalid-argument", "age");
  const name = nameArg(req.data?.name);
  return run(async (tx) => {
    const ref = db.doc(`users/${uid}`);
    const user = await tx.get(ref);
    const tomb = await tx.get(tombstones.doc(uid));
    if (tomb.exists || user.get("deleting") === true) throw new HttpsError("permission-denied", "account");
    if (!user.exists) {
      tx.set(ref, { display_name: name, age14_confirmed: true, deleting: false, created_at: FieldValue.serverTimestamp() });
      return { existing: false, restricted: false };
    }
    if (user.get("restricted") === true) return { existing: true, restricted: true };
    const mine = await tx.get(db.collectionGroup("members").where("uid", "==", uid));
    tx.update(ref, { display_name: name });
    for (const m of mine.docs) tx.update(m.ref, { display_name: name });
    return { existing: true, restricted: false };
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
    // summary_at(올린 시각)은 크루원에게 보일 이유가 없어 더 쓰지 않는다(R17). 예전에 쓴 값은 다음 합계 때 지운다
    for (const m of mine.docs) tx.update(m.ref, { season, ...values, summary_at: FieldValue.delete() });
    return { applied: true, crews: mine.size };
  });
});

// MARK: 계정 삭제 (R13, 05-design 6장)

/** 처음 삭제를 접수할 때 요구하는 재인증 기한(초). 앱은 Apple 재로그인 직후에 부른다. */
const REAUTH_SECONDS = 600;

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
  // 크루에서 빠진 뒤에는 새 차단 기록·신고 대상이 생기지 않는다(둘 다 멤버일 때만, 같은 멤버 문서를 읽는 트랜잭션)
  await purgeReports(uid);
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
  // 신고는 접수 90일 뒤 지운다(처리 여부와 무관, expire_at은 접수 때 한 번 정함)
  const expired = await reports.where("expire_at", "<", new Date()).limit(400).get();
  const batch = db.batch();
  for (const d of [...old.docs, ...expired.docs]) batch.delete(d.ref);
  await batch.commit();
});

// MARK: 신고 (R16, 05-design 6장)

const REPORT_KEEP_DAYS = 90;
const REPORTS_PER_DAY = 10;
const REPORT_GAP_MS = 5_000;

/** 같은 신고인지 가리는 값: 신고자·크루·대상 종류·대상·신고 당시 이름. 문서 ID에는 uid를 넣지 않는다(무작위 ID).
 *  신고자가 계정을 지우면 reporter_uid와 함께 지운다. */
function reportKey(reporter: string, crewId: string, target: string, targetUid: string, name: string) {
  return createHash("sha256").update([reporter, crewId, target, targetUid, name].join("\u0000")).digest("base64url");
}

function kstDay(t = Date.now()) {
  return new Date(t + 9 * 3600_000).toISOString().slice(0, 10);
}

/** 크루 이름이나 크루원 표시 이름을 신고한다. 같은 크루 멤버만. 신고 당시 이름을 복사해 둔다(이후 이름이 바뀌어도 판단할 수 있게).
 *  같은 신고자가 같은 대상·같은 이름을 다시 신고하면 새로 만들지 않는다. 이름이 바뀌었으면 새 신고다.
 *  남용 제한: 5초에 한 번, 새 신고는 하루(한국 날짜) 10건. */
export const reportName = onCall(async (req) => {
  const uid = uidOf(req);
  const crewId = idArg(req.data?.crewId, "crewId");
  const target = req.data?.target;
  if (target !== "crew_name" && target !== "display_name") throw new HttpsError("invalid-argument", "target");
  const targetUid = target === "display_name" ? idArg(req.data?.targetUid, "targetUid") : "";
  if (targetUid === uid) throw new HttpsError("invalid-argument", "self");

  const created = await run(async (tx) => {
    const user = await requireUser(tx, uid);
    const last = user.get("last_report_call") as Timestamp | undefined;
    if (last && Date.now() - last.toMillis() < REPORT_GAP_MS) throw new HttpsError("resource-exhausted", "slow-down");
    const crewRef = crews.doc(crewId);
    const crew = await tx.get(crewRef);
    const me = await tx.get(crewRef.collection("members").doc(uid));
    if (!crew.exists || !me.exists) throw new HttpsError("permission-denied", "member");
    let name: string, subject: string;
    if (target === "display_name") {
      const them = await tx.get(crewRef.collection("members").doc(targetUid));
      const theirAccount = await tx.get(db.doc(`users/${targetUid}`));
      if (!them.exists || theirAccount.get("deleting") === true) throw new HttpsError("not-found", "target");
      name = them.get("display_name") ?? "";
      subject = targetUid;
    } else {
      name = crew.get("name");
      subject = crew.get("owner_uid");  // 크루 이름은 크루장이 정한다
    }
    const key = reportKey(uid, crewId, target, subject, name);
    const same = await tx.get(reports.where("key", "==", key));
    const dup = same.docs.filter((d) => d.get("status") === "open");
    const day = kstDay();
    const count = user.get("report_day") === day ? (user.get("report_count") as number) ?? 0 : 0;
    if (dup.length > 0) {
      tx.update(user.ref, { last_report_call: FieldValue.serverTimestamp() });
      return null;
    }
    if (count >= REPORTS_PER_DAY) throw new HttpsError("resource-exhausted", "daily-limit");
    const ref = reports.doc();
    const now = Date.now();
    tx.set(ref, {
      crew_id: crewId, target, target_uid: subject, name, reporter_uid: uid, key,
      at: FieldValue.serverTimestamp(), expire_at: new Date(now + REPORT_KEEP_DAYS * 86_400_000), status: "open",
    });
    tx.update(user.ref, { last_report_call: FieldValue.serverTimestamp(), report_day: day, report_count: count + 1 });
    return ref.id;
  });
  // 커밋된 새 신고만 알린다(uid·이름 없이). 개발자는 Cloud Logging 알림을 받고, 매일 처리 스크립트로 미처리 목록을 본다.
  if (created) logger.warn("name reported", { reportId: created });
  return { reported: true };
});

/** 계정 삭제(R13): 내가 낸 신고는 신고자 정보를 지우고 남긴다(신고된 이름을 판단할 근거). 내가 대상인 신고는 지운다(이름이 이미 사라짐). */
async function purgeReports(uid: string) {
  const mine = await reports.where("reporter_uid", "==", uid).get();
  const about = await reports.where("target_uid", "==", uid).get();
  // ponytail: 한 배치(500개). 신고는 하루 10건·90일 보관이라 한 사람 몫이 넘지 않는다
  const batch = db.batch();
  for (const d of mine.docs) batch.update(d.ref, { reporter_uid: FieldValue.delete(), key: FieldValue.delete() });
  for (const d of about.docs) batch.delete(d.ref);
  await batch.commit();
}
export { submitSample } from "./samples.js";
