import { hash, compare } from "bcryptjs";
import { hashClientToken } from "./token";

// 会话相关（jose，Edge 安全）从 edge.ts 统一导出，middleware 直接从 ./edge 引入。
export { SESSION_COOKIE, signSession, verifySession } from "./edge";

export async function hashPassword(plain: string): Promise<string> {
  return hash(plain, 10);
}

export async function verifyPassword(plain: string, hashed: string): Promise<boolean> {
  return compare(plain, hashed);
}

// 长期客户端 token：随机生成，存 SHA-256，明文只返回一次。
export function signClientToken(): { token: string; hash: string } {
  const raw = crypto.randomUUID() + "." + crypto.randomUUID();
  const token = `vc_${raw.replace(/-/g, "")}`;
  return { token, hash: hashClientToken(token) };
}
