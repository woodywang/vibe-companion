import { redirect } from "next/navigation";
import Link from "next/link";
import { getCurrentUser } from "@/lib/auth/session";
import { dailyTotalsForUser, periodRange, globalLeaderboard } from "@/lib/usage/queries";
import { db, schema } from "@/lib/db";
import { eq, sql, desc } from "drizzle-orm";
import { ClientManager } from "@/components/ClientManager";
import { fmtTokens, fmtCost, fmtRate, fmtRelative, fmtDate } from "@/lib/ui/format";

export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  const user = await getCurrentUser();
  if (!user) redirect("/login");

  const { fromMs, toMs } = periodRange("week");
  const daily = await dailyTotalsForUser(user.id, fromMs, toMs);

  // 今日总量 + 最近 60s 速率
  const now = Date.now();
  const since60s = now - 60_000;
  const todayKey = new Date().toISOString().slice(0, 10);
  const todayRow = daily.find((d) => d.date === todayKey);
  const recent = await db
    .select({ total: sql<number>`SUM(${schema.usageEvents.totalTokens})` })
    .from(schema.usageEvents)
    .where(sql`${schema.usageEvents.userId} = ${user.id} AND ${schema.usageEvents.recordedAt} >= ${since60s}`);
  const tokensPerMin = Number(recent[0]?.total ?? 0);

  // 设备列表
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
    .where(eq(schema.clients.userId, user.id))
    .orderBy(desc(schema.clients.createdAt));

  // 全网排名中自己的位置
  const todayRange = periodRange("today");
  const lb = await globalLeaderboard(todayRange.fromMs, todayRange.toMs, 1000);
  const myRank = lb.find((e) => e.userId === user.id)?.rank ?? null;

  const weekTotal = daily.reduce((s, d) => s + d.totalTokens, 0);
  const weekCost = daily.reduce((s, d) => s + d.costUsd, 0);
  const maxBar = Math.max(1, ...daily.map((d) => d.totalTokens));

  return (
    <main className="mx-auto max-w-5xl px-6 py-10">
      {/* Header */}
      <div className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="font-display text-2xl font-bold">
            你好，{user.displayName} <span className="text-3xl">👋</span>
          </h1>
          <p className="text-sm text-stone-500">{user.email}</p>
        </div>
        <Link href="/leaderboard" className="rounded-lg border border-stone-300 px-4 py-2 text-sm font-medium hover:border-stone-400">
          🏆 排行榜
        </Link>
      </div>

      {/* 实时状态卡 */}
      <div className="mb-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          label="当前速率"
          value={fmtRate(tokensPerMin)}
          icon="🚴"
          accent={tokensPerMin > 0 ? "active" : "idle"}
          hint={rateHint(tokensPerMin)}
        />
        <StatCard label="今日 token" value={fmtTokens(todayRow?.totalTokens ?? 0)} icon="🔥" />
        <StatCard label="本周 token" value={fmtTokens(weekTotal)} icon="📈" />
        <StatCard label="本周花费" value={fmtCost(weekCost)} icon="💸" />
      </div>

      {/* 宠物状态条 */}
      <div className="mb-8 flex items-center gap-4 rounded-2xl border border-stone-200 bg-gradient-to-r from-brand-50 to-white p-5">
        <span className="text-5xl" style={{ animation: tokensPerMin > 0 ? "bounce 1s infinite" : "none" }}>
          {tokensPerMin === 0 ? "😴" : tokensPerMin > 20000 ? "🚀" : "🐰"}
        </span>
        <div className="flex-1">
          <div className="font-semibold text-stone-800">{petStatus(tokensPerMin)}</div>
          <div className="text-sm text-stone-500">{petHint(tokensPerMin)}</div>
        </div>
        {myRank && (
          <div className="text-right">
            <div className="text-2xl font-bold text-brand-600">#{myRank}</div>
            <div className="text-xs text-stone-400">今日全网排名</div>
          </div>
        )}
      </div>

      <div className="grid gap-8 lg:grid-cols-3">
        {/* 趋势图 */}
        <div className="lg:col-span-2 rounded-2xl border border-stone-200 bg-white p-6">
          <h2 className="mb-4 text-lg font-semibold">本周趋势</h2>
          <div className="flex h-40 items-end gap-2">
            {daily.length === 0 && (
              <div className="flex h-full w-full items-center justify-center text-sm text-stone-400">
                还没有数据，启动客户端 App 开始采集吧
              </div>
            )}
            {[...daily].reverse().map((d) => (
              <div key={d.date} className="flex flex-1 flex-col items-center gap-1">
                <div className="text-[10px] text-stone-400">{fmtTokens(d.totalTokens)}</div>
                <div
                  className="w-full rounded-t bg-brand-500 transition-all hover:bg-brand-600"
                  style={{ height: `${(d.totalTokens / maxBar) * 100}%`, minHeight: d.totalTokens > 0 ? 4 : 0 }}
                  title={`${d.date}: ${fmtTokens(d.totalTokens)} tokens / ${fmtCost(d.costUsd)}`}
                />
                <div className="text-[10px] text-stone-400">{fmtDate(d.date)}</div>
              </div>
            ))}
          </div>
        </div>

        {/* 设备管理 */}
        <div className="lg:col-span-1">
          <ClientManager initialClients={clients} />
        </div>
      </div>

      <style>{`@keyframes bounce{0%,100%{transform:translateY(0)}50%{transform:translateY(-6px)}}`}</style>
    </main>
  );
}

function StatCard({
  label,
  value,
  icon,
  accent,
  hint,
}: {
  label: string;
  value: string;
  icon: string;
  accent?: "active" | "idle";
  hint?: string;
}) {
  return (
    <div className="rounded-2xl border border-stone-200 bg-white p-5">
      <div className="mb-2 flex items-center justify-between">
        <span className="text-sm text-stone-500">{label}</span>
        <span className="text-xl">{icon}</span>
      </div>
      <div className="text-2xl font-bold text-stone-800">{value}</div>
      {hint && <div className="mt-1 text-xs text-stone-400">{hint}</div>}
      {accent === "active" && (
        <div className="mt-2 h-1 w-full overflow-hidden rounded-full bg-stone-100">
          <div className="h-full w-1/2 animate-pulse rounded-full bg-brand-500" />
        </div>
      )}
    </div>
  );
}

function rateHint(rpm: number): string {
  if (rpm === 0) return "休息中";
  if (rpm < 2000) return "慢悠悠";
  if (rpm < 10000) return "稳步推进";
  if (rpm < 30000) return "火力全开";
  return "喷射模式 🔥";
}

function petStatus(rpm: number): string {
  if (rpm === 0) return "宠物在打盹…";
  if (rpm < 2000) return "宠物在慢悠悠蹬车";
  if (rpm < 10000) return "宠物在稳步蹬车";
  if (rpm < 30000) return "宠物火力全开！";
  return "宠物喷射冲刺！🚀";
}

function petHint(rpm: number): string {
  if (rpm === 0) return "打开 AI 编程工具，宠物就会醒来";
  return `当前 ${fmtRate(rpm)} · 速率越高蹬得越快`;
}
