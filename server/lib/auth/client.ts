import { NextRequest, NextResponse } from "next/server";
import { db, schema } from "@/lib/db";
import { verifyClientToken } from "@/lib/auth";
import { eq } from "drizzle-orm";

// 从 Authorization: Bearer <client_token> 解析客户端身份
export async function resolveClient(req: NextRequest) {
  const auth = req.headers.get("authorization") ?? "";
  const m = auth.match(/^Bearer\s+(vc_[\w.]+)$/i);
  if (!m) return { ok: false as const, error: "missing_bearer_token" };
  const token = m[1];

  // 客户端 token 数量有限，逐个比较 hash；MVP 可接受
  const allClients = await db
    .select({
      id: schema.clients.id,
      userId: schema.clients.userId,
      tokenHash: schema.clients.clientTokenHash,
      deviceName: schema.clients.deviceName,
    })
    .from(schema.clients)
    .all();

  for (const c of allClients) {
    if (await verifyClientToken(token, c.tokenHash)) {
      await db.update(schema.clients)
        .set({ lastSeenAt: Date.now() })
        .where(eq(schema.clients.id, c.id));
      return {
        ok: true as const,
        client: { id: c.id, userId: c.userId, deviceName: c.deviceName },
      };
    }
  }
  return { ok: false as const, error: "invalid_client_token" };
}

export function jsonError(status: number, error: string, extra?: Record<string, unknown>) {
  return NextResponse.json({ error, ...extra }, { status });
}
