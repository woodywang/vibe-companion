"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { fmtTokens, fmtCost } from "@/lib/ui/format";

type Period = "today" | "week" | "month";
interface Entry {
  rank: number;
  userId: string;
  displayName: string;
  totalTokens: number;
  costUsd: number;
}

export default function LeaderboardPage() {
  const [period, setPeriod] = useState<Period>("today");
  const [entries, setEntries] = useState<Entry[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    fetch(`/api/leaderboard/global?period=${period}`)
      .then((r) => r.json())
      .then((d) => setEntries(d.entries ?? []))
      .finally(() => setLoading(false));
  }, [period]);

  return (
    <main className="mx-auto max-w-3xl px-6 py-10">
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="font-display text-2xl font-bold">🏆 全网排行榜</h1>
          <p className="text-sm text-stone-500">谁的 token 烧得最猛？</p>
        </div>
        <Link href="/dashboard" className="text-sm text-brand-600 hover:underline">
          回到我的看板
        </Link>
      </div>

      {/* 周期切换 */}
      <div className="mb-6 inline-flex rounded-xl border border-stone-200 bg-white p-1">
        {(["today", "week", "month"] as Period[]).map((p) => (
          <button
            key={p}
            onClick={() => setPeriod(p)}
            className={`rounded-lg px-4 py-1.5 text-sm font-medium transition ${
              period === p ? "bg-brand-600 text-white" : "text-stone-600 hover:bg-stone-100"
            }`}
          >
            {p === "today" ? "今日" : p === "week" ? "本周" : "本月"}
          </button>
        ))}
      </div>

      {/* 领奖台（前三） */}
      {!loading && entries.length >= 3 && (
        <div className="mb-6 grid grid-cols-3 gap-3">
          {[1, 0, 2].map((idx) => {
            const e = entries[idx];
            const medal = idx === 0 ? "🥇" : idx === 1 ? "🥈" : "🥉";
            const height = idx === 0 ? "h-32" : "h-24";
            return (
              <div key={e.userId} className="flex flex-col items-center">
                <div className="mb-2 text-3xl">{medal}</div>
                <div
                  className={`flex ${height} w-full flex-col items-center justify-end rounded-t-xl bg-gradient-to-b ${
                    idx === 0 ? "from-yellow-200 to-yellow-50" : "from-stone-200 to-stone-50"
                  } p-3`}
                >
                  <div className="max-w-full truncate text-sm font-semibold">{e.displayName}</div>
                  <div className="text-xs text-stone-500">{fmtTokens(e.totalTokens)}</div>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* 列表 */}
      <div className="overflow-hidden rounded-2xl border border-stone-200 bg-white">
        {loading ? (
          <div className="py-12 text-center text-sm text-stone-400">加载中…</div>
        ) : entries.length === 0 ? (
          <div className="py-12 text-center text-sm text-stone-400">
            还没有数据。注册并启动客户端，成为榜首！
          </div>
        ) : (
          <ul className="divide-y divide-stone-100">
            {entries.map((e) => (
              <li key={e.userId} className="flex items-center gap-4 px-5 py-3">
                <span className={`w-8 text-center font-bold ${e.rank <= 3 ? "text-brand-600" : "text-stone-400"}`}>
                  {e.rank}
                </span>
                <span className="flex-1 truncate font-medium text-stone-800">{e.displayName}</span>
                <span className="text-sm text-stone-500">{fmtCost(e.costUsd)}</span>
                <span className="w-24 text-right font-mono text-sm font-semibold text-stone-700">
                  {fmtTokens(e.totalTokens)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </main>
  );
}
