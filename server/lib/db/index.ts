import { createClient } from "@libsql/client";
import { drizzle } from "drizzle-orm/libsql";
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import * as schema from "./schema";

// DATABASE_URL 既可以是本地文件路径，也可以是 Turso 远程地址 (libsql://...)
const dbUrl = process.env.DATABASE_URL ?? "file:./.data/app.db";

// 本地文件型 SQLite 需确保目录存在
if (dbUrl.startsWith("file:")) {
  const filePath = dbUrl.slice("file:".length);
  const dir = path.dirname(path.resolve(process.cwd(), filePath));
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

const libsql = createClient({
  url: dbUrl,
  // 远程 Turso 需要 authToken；本地文件不需要
  authToken: process.env.DATABASE_AUTH_TOKEN,
});

export const db = drizzle(libsql, { schema });
export { schema };
