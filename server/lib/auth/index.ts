import { hash, compare } from "bcryptjs";
import { SignJWT, jwtVerify } from "jose";

const secret = new TextEncoder().encode(
  process.env.AUTH_SECRET ?? "dev-secret-change-me-in-production"
);

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

// 长期客户端 token，用于 macOS 客户端上传（不记名 JWT，校验时查 DB hash 更安全）
export async function signClientToken(clientId: string): Promise<{ token: string; hash: string }> {
  const raw = crypto.randomUUID() + "." + crypto.randomUUID();
  const token = `vc_${raw.replace(/-/g, "")}`;
  // 存储 hash，明文只返回一次
  const hashStr = await hash(token, 10);
  return { token, hash: hashStr };
}

export async function verifyClientToken(token: string, storedHash: string): Promise<boolean> {
  return compare(token, storedHash);
}
