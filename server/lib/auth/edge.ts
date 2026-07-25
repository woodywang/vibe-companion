import { SignJWT, jwtVerify } from "jose";
import { assertAuthSecret } from "./secret";

const secret = new TextEncoder().encode(assertAuthSecret(process.env));

export const SESSION_COOKIE = "vc_session";

// 短期 JWT，用于 Web 浏览器会话（cookie）。仅依赖 jose，可在 Edge 运行时打包。
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
