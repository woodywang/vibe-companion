import { createHash } from "node:crypto";

// 客户端 token 是高熵随机串，用快哈希（SHA-256）即可，便于唯一索引 O(1) 查询。
export function hashClientToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}
