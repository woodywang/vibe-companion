import { hash, compare } from "bcryptjs";
import { SignJWT, jwtVerify } from "jose";
import { hashClientToken } from "./token";
import { assertAuthSecret } from "./secret";

const secret = new TextEncoder().encode(assertAuthSecret(process.env));

export const SESSION_COOKIE = "vc_session";

export async function hashPassword(plain: string): Promise<string> {
  return hash(plain, 10);
}

export async function verifyPassword(plain: string, hashed: string): Promise<boolean> {
  return compare(plain, hashed);
}

// 短期 JWT，用于 Web 浏览器会话（cookie）
export async function signSession(userId: string): Promise<string> {
  return new SignJWT({ sub: userId, kind: "session" })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(secret);
}

export async function verifySession(token: string): Promise<{ sub: string } | null> {
  try {
    const { payload } = await jwtVerify(token, secret);
    if (payload.kind !== "session") return null;
    return { sub: payload.sub! };
  } catch {
    return null;
  }
}

// 长期客户端 token：随机生成，存 SHA-256，明文只返回一次。
export function signClientToken(): { token: string; hash: string } {
  const raw = crypto.randomUUID() + "." + crypto.randomUUID();
  const token = `vc_${raw.replace(/-/g, "")}`;
  return { token, hash: hashClientToken(token) };
}
