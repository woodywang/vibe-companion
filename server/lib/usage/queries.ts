import { db, schema } from "@/lib/db";
import { eq, gte, sql, and, desc } from "drizzle-orm";

export interface DailyTotal {
  date: string; // YYYY-MM-DD
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
  reasoningTokens: number;
  totalTokens: number;
  weightedTokens: number;
  costUsd: number;
}

// 按 user_id + 日期范围聚合每日总量
export async function dailyTotalsForUser(userId: string, fromMs: number, toMs: number): Promise<DailyTotal[]> {
  const rows = await db
    .select({
      date: sql<string>`date(${schema.usageEvents.recordedAt} / 1000, 'unixepoch', 'localtime')`.as("date"),
      inputTokens: sql<number>`SUM(${schema.usageEvents.inputTokens})`.as("input_tokens"),
      outputTokens: sql<number>`SUM(${schema.usageEvents.outputTokens})`.as("output_tokens"),
      cacheCreationTokens: sql<number>`SUM(${schema.usageEvents.cacheCreationTokens})`.as("cache_creation_tokens"),
      cacheReadTokens: sql<number>`SUM(${schema.usageEvents.cacheReadTokens})`.as("cache_read_tokens"),
      reasoningTokens: sql<number>`SUM(${schema.usageEvents.reasoningTokens})`.as("reasoning_tokens"),
      totalTokens: sql<number>`SUM(${schema.usageEvents.totalTokens})`.as("total_tokens"),
      weightedTokens: sql<number>`SUM(${schema.usageEvents.weightedTokens})`.as("weighted_tokens"),
      costUsd: sql<number>`SUM(${schema.usageEvents.costUsd})`.as("cost_usd"),
    })
    .from(schema.usageEvents)
    .where(
      and(
        eq(schema.usageEvents.userId, userId),
        gte(schema.usageEvents.recordedAt, fromMs),
        sql`${schema.usageEvents.recordedAt} <= ${toMs}`
      )
    )
    .groupBy(sql`date`)
    .orderBy(desc(sql`date`));
  return rows.map((r) => ({
    date: r.date,
    inputTokens: Number(r.inputTokens ?? 0),
    outputTokens: Number(r.outputTokens ?? 0),
    cacheCreationTokens: Number(r.cacheCreationTokens ?? 0),
    cacheReadTokens: Number(r.cacheReadTokens ?? 0),
    reasoningTokens: Number(r.reasoningTokens ?? 0),
    totalTokens: Number(r.totalTokens ?? 0),
    weightedTokens: Number(r.weightedTokens ?? 0),
    costUsd: Number(r.costUsd ?? 0),
  }));
}

export interface LeaderboardEntry {
  rank: number;
  userId: string;
  displayName: string;
  // NOTE: intentionally the WEIGHTED token sum (input+output+cacheCreation+reasoning,
  // excludes cacheRead), not the raw totalTokens column. Kept the "totalTokens" name to
  // preserve the API shape — do not swap in raw totalTokens / reintroduce cacheRead here.
  totalTokens: number;
  costUsd: number;
}

// 全网排名：按指定时间窗聚合所有 user 的 token 总量
export async function globalLeaderboard(fromMs: number, toMs: number, limit = 100): Promise<LeaderboardEntry[]> {
  const rows = await db
    .select({
      userId: schema.usageEvents.userId,
      // Aliased as "total_tokens" for API-shape compatibility, but this SUMs weightedTokens
      // (input+output+cacheCreation+reasoning, excludes cacheRead) — not the raw totalTokens
      // column. Keep it weighted; don't reintroduce cacheRead here.
      totalTokens: sql<number>`SUM(${schema.usageEvents.weightedTokens})`.as("total_tokens"),
      costUsd: sql<number>`SUM(${schema.usageEvents.costUsd})`.as("cost_usd"),
    })
    .from(schema.usageEvents)
    .where(and(gte(schema.usageEvents.recordedAt, fromMs), sql`${schema.usageEvents.recordedAt} <= ${toMs}`))
    .groupBy(schema.usageEvents.userId)
    .orderBy(desc(sql`total_tokens`))
    .limit(limit);

  // 关联用户名
  const userIds = rows.map((r) => r.userId);
  if (!userIds.length) return [];
  const users = await db
    .select({ id: schema.users.id, displayName: schema.users.displayName })
    .from(schema.users)
    .where(sql`${schema.users.id} IN (${sql.join(userIds.map((id) => sql`${id}`), sql`, `)})`);

  const nameMap = new Map(users.map((u) => [u.id, u.displayName]));
  return rows.map((r, i) => ({
    rank: i + 1,
    userId: r.userId,
    displayName: nameMap.get(r.userId) ?? "anon",
    totalTokens: Number(r.totalTokens ?? 0),
    costUsd: Number(r.costUsd ?? 0),
  }));
}

// 时间窗 helper
export function periodRange(period: "today" | "week" | "month"): { fromMs: number; toMs: number } {
  const now = new Date();
  const toMs = now.getTime();
  const start = new Date(now);
  start.setHours(0, 0, 0, 0);
  if (period === "today") {
    return { fromMs: start.getTime(), toMs };
  }
  if (period === "week") {
    start.setDate(start.getDate() - 6); // 含今天共 7 天
    return { fromMs: start.getTime(), toMs };
  }
  // month
  start.setMonth(start.getMonth(), 1);
  start.setHours(0, 0, 0, 0);
  return { fromMs: start.getTime(), toMs };
}
