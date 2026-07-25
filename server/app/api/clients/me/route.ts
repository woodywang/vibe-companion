import { NextResponse } from "next/server";
import { requireUser } from "@/lib/auth/session";
import { db, schema } from "@/lib/db";
import { eq } from "drizzle-orm";

// 列出当前用户的所有客户端设备
export async function GET() {
  let user;
  try {
    user = await requireUser();
  } catch {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const clients = await db
    .select({
      id: schema.clients.id,
      deviceName: schema.clients.deviceName,
      platform: schema.clients.platform,
      machineId: schema.clients.machineId,
      lastSeenAt: schema.clients.lastSeenAt,
      createdAt: schema.clients.createdAt,
    })
    .from(schema.clients)
    .where(eq(schema.clients.userId, user.id));

  return NextResponse.json({ clients });
}
