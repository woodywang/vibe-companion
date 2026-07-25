import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { globalLeaderboard, periodRange } from "@/lib/usage/queries";

const query = z.object({
  period: z.enum(["today", "week", "month"]).default("today"),
});

export async function GET(req: NextRequest) {
  const url = new URL(req.url);
  const parsed = query.safeParse(Object.fromEntries(url.searchParams));
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid_query" }, { status: 400 });
  }
  const { fromMs, toMs } = periodRange(parsed.data.period);
  const entries = await globalLeaderboard(fromMs, toMs, 100);
  return NextResponse.json({ period: parsed.data.period, entries });
}
