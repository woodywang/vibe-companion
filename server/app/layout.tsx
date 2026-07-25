import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Vibe Companion",
  description: "游戏化的 vibe coding token 追踪与排名",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh">
      <body className="min-h-screen antialiased">{children}</body>
    </html>
  );
}
