/** 경합으로 오래 기다린 트랜잭션 안 쿼리를 SDK가 다시 보내면, 그사이 닫힌 트랜잭션이라 INVALID_ARGUMENT로 온다.
 *  커밋되지 않았으므로 경합(aborted)으로 보고 다시 시도해도 된다. 진짜 입력 오류(다른 INVALID_ARGUMENT)는 그대로 둔다. */
export function isClosedTransaction(e: unknown): boolean {
  const x = e as { code?: unknown; details?: unknown };
  return x.code === 3 && typeof x.details === "string" && x.details.includes("Transaction is invalid or closed");
}
