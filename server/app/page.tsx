import Link from "next/link";

export default function HomePage() {
  return (
    <main className="min-h-screen">
      {/* Hero */}
      <section className="relative overflow-hidden">
        <div className="mx-auto max-w-5xl px-6 pt-20 pb-24 text-center">
          <div className="mb-6 inline-flex items-center gap-2 rounded-full bg-brand-100 px-4 py-1.5 text-sm font-medium text-brand-700">
            <span className="animate-pulse">🚴</span> 让你的 token 消耗看得见
          </div>
          <h1 className="font-display text-5xl md:text-6xl font-bold tracking-tight">
            Vibe <span className="text-brand-600">Companion</span>
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-lg text-stone-600">
            一只在菜单栏里蹬自行车的宠物，陪你的 AI 编程之旅。
            速率越高蹬得越快 —— 实时采集 Claude Code / Codex 的 token 消耗，
            上传云端，和队友一起比拼排名。
          </p>
          <div className="mt-10 flex items-center justify-center gap-4">
            <Link
              href="/register"
              className="rounded-xl bg-brand-600 px-6 py-3 font-semibold text-white shadow-lg shadow-brand-600/30 transition hover:bg-brand-700 hover:scale-105"
            >
              免费开始
            </Link>
            <Link
              href="/leaderboard"
              className="rounded-xl border border-stone-300 bg-white px-6 py-3 font-semibold text-stone-700 transition hover:border-stone-400"
            >
              看排行榜 →
            </Link>
          </div>

          {/* 宠物预览（占位，后续替换为 Lottie） */}
          <div className="mx-auto mt-16 flex max-w-md items-end justify-center gap-2 rounded-2xl border border-stone-200 bg-gradient-to-b from-stone-50 to-white p-8 shadow-sm">
            <span className="text-6xl" style={{ animation: "bounce 1s infinite" }}>
              🐹
            </span>
            <span className="text-5xl" style={{ animation: "bounce 1s infinite 0.1s" }}>
              🚲
            </span>
            <div className="ml-4 text-left">
              <div className="text-2xl font-bold text-brand-600">8,500</div>
              <div className="text-xs text-stone-500">tokens / min</div>
            </div>
          </div>
        </div>
        <style>{`@keyframes bounce{0%,100%{transform:translateY(0)}50%{transform:translateY(-6px)}}`}</style>
      </section>

      {/* Features */}
      <section className="border-t border-stone-200 bg-white">
        <div className="mx-auto grid max-w-5xl gap-8 px-6 py-20 md:grid-cols-3">
          <Feature
            icon="📡"
            title="实时采集"
            desc="监听 Claude Code 与 Codex CLI 的本地会话文件，近实时统计每回合的 token 用量，无需手动上报。"
          />
          <Feature
            icon="🐰"
            title="游戏化宠物"
            desc="悬浮在桌面的小动物蹬着自行车，token 速率越高蹬得越快。离线时打盹，冲刺时喷火。"
          />
          <Feature
            icon="🏆"
            title="组队 & 排名"
            desc="多台设备自动汇总，组建队伍比拼团队 token 产出，或参与全网日榜 / 周榜 / 月榜。"
          />
        </div>
      </section>

      <footer className="border-t border-stone-200 py-8 text-center text-sm text-stone-400">
        Vibe Companion · MVP
      </footer>
    </main>
  );
}

function Feature({ icon, title, desc }: { icon: string; title: string; desc: string }) {
  return (
    <div className="rounded-2xl border border-stone-200 p-6 transition hover:shadow-md">
      <div className="mb-3 text-3xl">{icon}</div>
      <h3 className="mb-2 font-semibold text-stone-800">{title}</h3>
      <p className="text-sm leading-relaxed text-stone-500">{desc}</p>
    </div>
  );
}
