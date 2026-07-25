const DEV_FALLBACK = "dev-secret-change-me-in-production";

export function assertAuthSecret(env: { AUTH_SECRET?: string; NODE_ENV?: string }): string {
  if (env.AUTH_SECRET) return env.AUTH_SECRET;
  if (env.NODE_ENV === "production") {
    throw new Error("AUTH_SECRET must be set in production");
  }
  console.warn("[auth] AUTH_SECRET not set — using insecure dev fallback");
  return DEV_FALLBACK;
}
