import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireUser } from "@/lib/auth/session";
import { db, schema } from "@/lib/db";
import { dailyTotalsForUser, periodRange, effectiveTokensSinceForUser } from "@/lib/usage/queries";
import { eq } from "drizzle-orm";

const query = z.object({
  period: z.enum(["today", "week", "month"]).default("week"),
  from: z.coerce.number().optional(),
  to: z.coerce.number().optional(),
});

export async function GET(req: NextRequest) {
  let user;
  try {
    user = await requireUser();
  } catch {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const url = new URL(req.url);
  const parsed = query.safeParse(Object.fromEntries(url.searchParams));
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid_query" }, { status: 400 });
  }
  const { fromMs, toMs } =
    parsed.data.from && parsed.data.to
      ? { fromMs: parsed.data.from, toMs: parsed.data.to }
      : periodRange(parsed.data.period);

  const daily = await dailyTotalsForUser(user.id, fromMs, toMs);

  // 今日实时总量 + 当前速率（最近 60s，effective 口径排除 cache_read）
  const now = Date.now();
  const since60s = now - 60_000;
  const tokensLast60s = await effectiveTokensSinceForUser(user.id, since60s);

  // 设备列表
  const clients = await db
    .select({
      id: schema.clients.id,
      deviceName: schema.clients.deviceName,
      platform: schema.clients.platform,
      lastSeenAt: schema.clients.lastSeenAt,
      createdAt: schema.clients.createdAt,
    })
    .from(schema.clients)
    .where(eq(schema.clients.userId, user.id));

  return NextResponse.json({
    period: parsed.data.period,
    daily,
    todayTotal: daily.find((d) => d.date === new Date().toISOString().slice(0, 10))?.totalTokens ?? 0,
    tokensPerMinute: tokensLast60s,
    clients,
  });
}
