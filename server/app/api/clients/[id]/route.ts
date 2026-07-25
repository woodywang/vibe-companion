import { NextResponse } from "next/server";
import { requireUser } from "@/lib/auth/session";
import { db, schema } from "@/lib/db";
import { and, eq } from "drizzle-orm";

// 删除当前用户名下的指定设备（级联删除其用量事件）
export async function DELETE(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  let user;
  try {
    user = await requireUser();
  } catch {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  const { id } = await params;
  const rows = await db
    .select({ id: schema.clients.id })
    .from(schema.clients)
    .where(and(eq(schema.clients.id, id), eq(schema.clients.userId, user.id)))
    .limit(1);
  if (!rows[0]) return NextResponse.json({ error: "not_found" }, { status: 404 });
  await db.delete(schema.clients).where(eq(schema.clients.id, id));
  return NextResponse.json({ ok: true });
}
