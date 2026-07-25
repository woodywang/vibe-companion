"use client";

import { useState } from "react";
import { fmtRelative } from "@/lib/ui/format";

interface ClientDevice {
  id: string;
  deviceName: string;
  platform: string;
  machineId: string | null;
  lastSeenAt: number | null;
  createdAt: number;
}

export function ClientManager({ initialClients }: { initialClients: ClientDevice[] }) {
  const [clients, setClients] = useState(initialClients);
  const [deviceName, setDeviceName] = useState("");
  const [newToken, setNewToken] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [copied, setCopied] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);

  async function register(e: React.FormEvent) {
    e.preventDefault();
    if (!deviceName.trim()) return;
    setLoading(true);
    setError(null);
    setNewToken(null);
    try {
      const res = await fetch("/api/clients/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          deviceName: deviceName.trim(),
          machineId: null,
          platform: "macos",
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error === "unauthorized" ? "请先登录" : "注册失败");
        return;
      }
      setNewToken(data.clientToken);
      setClients((prev) => [
        {
          id: data.clientId,
          deviceName: deviceName.trim(),
          platform: "macos",
          machineId: null,
          lastSeenAt: Date.now(),
          createdAt: Date.now(),
        },
        ...prev,
      ]);
      setDeviceName("");
    } catch {
      setError("网络错误");
    } finally {
      setLoading(false);
    }
  }

  function copyToken() {
    if (!newToken) return;
    navigator.clipboard.writeText(newToken);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  async function removeDevice(id: string) {
    if (deletingId) return;
    if (!confirm("删除该设备将一并清除其历史用量，确认？")) return;
    setDeletingId(id);
    try {
      const res = await fetch(`/api/clients/${id}`, { method: "DELETE" });
      // 404 表示设备已经不存在（例如重复点击/已在别处删除），按成功处理
      if (res.ok || res.status === 404) setClients((prev) => prev.filter((c) => c.id !== id));
      else setError("删除失败");
    } finally {
      setDeletingId(null);
    }
  }

  return (
    <div className="rounded-2xl border border-stone-200 bg-white p-6">
      <h2 className="mb-1 text-lg font-semibold">我的设备</h2>
      <p className="mb-4 text-sm text-stone-500">
        每台 macOS 设备需注册后获取 Client Token，填入客户端 App 设置即可上传。
      </p>

      {/* 注册新设备 */}
      <form onSubmit={register} className="mb-6 flex gap-2">
        <input
          type="text"
          placeholder="设备名，如 Woody-MacBook"
          value={deviceName}
          onChange={(e) => setDeviceName(e.target.value)}
          className="flex-1 rounded-lg border border-stone-300 px-3 py-2 text-sm outline-none focus:border-brand-500"
        />
        <button
          type="submit"
          disabled={loading || !deviceName.trim()}
          className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700 disabled:opacity-50"
        >
          {loading ? "..." : "添加设备"}
        </button>
      </form>

      {error && <p className="mb-4 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-600">{error}</p>}

      {/* 新 token 展示（仅一次） */}
      {newToken && (
        <div className="mb-6 rounded-xl border-2 border-dashed border-brand-400 bg-brand-50 p-4">
          <p className="mb-2 text-sm font-semibold text-brand-700">
            ✅ 设备已注册！请复制下面的 Token 填入客户端 App：
          </p>
          <div className="flex items-center gap-2">
            <code className="flex-1 truncate rounded bg-white px-3 py-2 text-xs">{newToken}</code>
            <button
              onClick={copyToken}
              className="rounded-lg bg-brand-600 px-3 py-2 text-xs font-semibold text-white hover:bg-brand-700"
            >
              {copied ? "已复制 ✓" : "复制"}
            </button>
          </div>
          <p className="mt-2 text-xs text-brand-600">⚠️ 此 Token 仅显示一次，请妥善保存。</p>
        </div>
      )}

      {/* 设备列表 */}
      <ul className="divide-y divide-stone-100">
        {clients.length === 0 && (
          <li className="py-4 text-center text-sm text-stone-400">还没有设备</li>
        )}
        {clients.map((c) => (
          <li key={c.id} className="flex items-center justify-between py-3">
            <div>
              <div className="font-medium text-stone-800">{c.deviceName}</div>
              <div className="text-xs text-stone-400">
                {c.platform} · 活跃 {fmtRelative(c.lastSeenAt)}
              </div>
            </div>
            <div className="flex items-center">
              <button
                onClick={() => removeDevice(c.id)}
                disabled={deletingId === c.id}
                className="mr-2 text-xs text-red-500 hover:underline disabled:opacity-50"
              >
                {deletingId === c.id ? "删除中…" : "删除"}
              </button>
              <span
                className={`h-2 w-2 rounded-full ${
                  c.lastSeenAt && Date.now() - c.lastSeenAt < 5 * 60_000
                    ? "bg-green-500"
                    : "bg-stone-300"
                }`}
                title={c.lastSeenAt ? fmtRelative(c.lastSeenAt) : "从未活跃"}
              />
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
