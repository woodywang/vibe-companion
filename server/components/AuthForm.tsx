"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";

export function AuthForm({ mode }: { mode: "login" | "register" }) {
  const router = useRouter();
  const isRegister = mode === "register";
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const body = isRegister
        ? { email, password, displayName }
        : { email, password };
      const res = await fetch(`/api/auth/${mode}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(mapError(data.error));
        return;
      }
      router.push("/dashboard");
      router.refresh();
    } catch {
      setError("网络错误，请重试");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-stone-50 px-4">
      <div className="w-full max-w-sm">
        <Link href="/" className="mb-8 block text-center">
          <span className="text-2xl">🚴</span>
          <span className="ml-2 font-display text-xl font-bold">Vibe Companion</span>
        </Link>
        <form onSubmit={submit} className="space-y-4 rounded-2xl border border-stone-200 bg-white p-6 shadow-sm">
          <h1 className="text-lg font-semibold">
            {isRegister ? "创建账户" : "登录"}
          </h1>
          {isRegister && (
            <Field label="昵称">
              <input
                type="text"
                required
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                className="input"
                placeholder="你的展示名"
              />
            </Field>
          )}
          <Field label="邮箱">
            <input
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="input"
              placeholder="you@example.com"
            />
          </Field>
          <Field label="密码">
            <input
              type="password"
              required
              minLength={6}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="input"
              placeholder="至少 6 位"
            />
          </Field>
          {error && (
            <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-600">{error}</p>
          )}
          <button
            type="submit"
            disabled={loading}
            className="w-full rounded-xl bg-brand-600 py-2.5 font-semibold text-white transition hover:bg-brand-700 disabled:opacity-50"
          >
            {loading ? "..." : isRegister ? "注册" : "登录"}
          </button>
          <p className="text-center text-sm text-stone-500">
            {isRegister ? "已有账户？" : "还没有账户？"}{" "}
            <Link href={isRegister ? "/login" : "/register"} className="font-medium text-brand-600 hover:underline">
              {isRegister ? "去登录" : "去注册"}
            </Link>
          </p>
        </form>
      </div>
      <style jsx>{`
        :global(.input) {
          width: 100%;
          border-radius: 0.5rem;
          border: 1px solid #d6d3d1;
          padding: 0.5rem 0.75rem;
          font-size: 0.875rem;
          outline: none;
        }
        :global(.input:focus) {
          border-color: #f97316;
          box-shadow: 0 0 0 3px rgba(249, 115, 22, 0.15);
        }
      `}</style>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-stone-600">{label}</span>
      {children}
    </label>
  );
}

function mapError(code: string): string {
  switch (code) {
    case "email_taken":
      return "该邮箱已被注册";
    case "invalid_credentials":
      return "邮箱或密码错误";
    case "invalid_body":
      return "输入有误，请检查";
    default:
      return "出错了，请重试";
  }
}
