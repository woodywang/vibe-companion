import { NextRequest, NextResponse } from "next/server";
import { db, schema } from "@/lib/db";
import { hashClientToken } from "@/lib/auth/token";
import { eq } from "drizzle-orm";

// 从 Authorization: Bearer <client_token> 解析客户端身份
export async function resolveClient(req: NextRequest) {
  const auth = req.headers.get("authorization") ?? "";
  const m = auth.match(/^Bearer\s+(vc_[\w.]+)$/i);
  if (!m) return { ok: false as const, error: "missing_bearer_token" };
  const hash = hashClientToken(m[1]);

  const rows = await db
    .select({
      id: schema.clients.id,
      userId: schema.clients.userId,
      deviceName: schema.clients.deviceName,
    })
    .from(schema.clients)
    .where(eq(schema.clients.clientTokenHash, hash))
    .limit(1);

  const c = rows[0];
  if (!c) return { ok: false as const, error: "invalid_client_token" };

  await db.update(schema.clients).set({ lastSeenAt: Date.now() }).where(eq(schema.clients.id, c.id));
  return { ok: true as const, client: { id: c.id, userId: c.userId, deviceName: c.deviceName } };
}

export function jsonError(status: number, error: string, extra?: Record<string, unknown>) {
  return NextResponse.json({ error, ...extra }, { status });
}
