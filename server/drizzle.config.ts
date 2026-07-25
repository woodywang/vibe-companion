import type { Config } from "drizzle-kit";

export default {
  schema: "./lib/db/schema.ts",
  out: "./drizzle",
  dialect: "turso",
  dbCredentials: {
    url: process.env.DATABASE_URL ?? "file:./.data/app.db",
    authToken: process.env.DATABASE_AUTH_TOKEN,
  },
} satisfies Config;
