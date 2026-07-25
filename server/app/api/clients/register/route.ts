import { NextRequest } from "next/server";
import { z } from "zod";
import { db, schema } from "@/lib/db";
import { signClientToken } from "@/lib/auth";
import { requireUser } from "@/lib/auth/session";
import { nanoid } from "nanoid";

const body = z.object({
  deviceName: z.string().min(1).max(128),
  machineId: z.string().max(255).optional(),
  platform: z.string().max(32).default("macos"),
});

// 需浏览器会话登录（cookie）
export async function POST(req: NextRequest) {
  let user;
  try {
    user = await requireUser();
  } catch {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  let parsed;
  try {
    parsed = body.parse(await req.json());
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400 });
  }

  const id = nanoid();
  const { token, hash } = signClientToken();
  await db.insert(schema.clients)
    .values({
      id,
      userId: user.id,
      deviceName: parsed.deviceName,
      machineId: parsed.machineId,
      clientTokenHash: hash,
      platform: parsed.platform,
      lastSeenAt: Date.now(),
    });

  // client_token 明文仅返回一次，客户端需持久保存
  return Response.json({ ok: true, clientId: id, clientToken: token });
}
