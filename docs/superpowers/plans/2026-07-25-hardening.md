# VibeCompanion Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix code-review findings H1–H4 and M1–M7 across the Next.js server and Swift client, with regression tests on both sides.

**Architecture:** Server work is TypeScript in `server/` (Next.js App Router + Drizzle + libsql), tested with vitest against pure functions. Client work is Swift in `client/VibeCompanion/`, tested with XCTest via SwiftPM. Each fix isolates its logic into a pure, testable unit, then wires it into the app.

**Tech Stack:** Next.js 15, Drizzle ORM, libsql, zod, jose, bcryptjs (passwords only), Node `crypto` (token hashing); Swift 5.9, SwiftPM, GRDB, Lottie, XCTest.

## Global Constraints

- Node `crypto.createHash("sha256")` for client-token hashing; `bcryptjs` stays for user passwords only.
- Token field upper bound: `50_000_000` per field. `recordedAt` window: `[Date.now() - 90*86400_000, Date.now() + 600_000]`.
- Weighted tokens formula (rate + leaderboard): `input + output + cacheCreation + reasoning` (excludes `cacheRead`). `totalTokens` unchanged for storage/cost.
- Client-token auth switches cleanly to SHA-256; old bcrypt-hashed clients become invalid (no real users — acceptable). Re-run `npm run db:push --force` after any schema change.
- Swift new pure logic must be `internal` (not `private`) so `@testable import VibeCompanion` can reach it.
- Commit after every task. Conventional-commit messages.
- All commands run from the worktree root `/Users/woody/Workspaces/vide-companion/.claude/worktrees/hardening` (server cmds from `server/`, swift cmds from `client/`).

---

## File Structure

**Server — create:**
- `server/vitest.config.ts` — vitest node config
- `server/lib/auth/token.ts` — `hashClientToken()`
- `server/lib/auth/token.test.ts`
- `server/lib/auth/secret.ts` — `assertAuthSecret()` + resolved secret
- `server/lib/auth/secret.test.ts`
- `server/lib/usage/schema.ts` — shared zod `eventSchema` / `bodySchema` + bounds constants
- `server/lib/usage/schema.test.ts`
- `server/lib/usage/weighted.test.ts`
- `server/app/api/clients/[id]/route.ts` — `DELETE`

**Server — modify:**
- `server/package.json` — add vitest + `test` script
- `server/lib/db/schema.ts` — unique index on `clientTokenHash`; `weightedTokens` column
- `server/lib/auth/index.ts` — `signClientToken()` sha256, drop unused param; use resolved secret
- `server/lib/auth/client.ts` — `resolveClient` O(1) hash lookup
- `server/app/api/clients/register/route.ts` — call sites
- `server/app/api/usage/batch/route.ts` — import shared schema; compute `weightedTokens`
- `server/lib/usage/types.ts` — `weightedTokens()` helper
- `server/lib/usage/queries.ts` — leaderboard/daily/recent use `weighted_tokens`
- `server/app/api/usage/me/route.ts`, `server/app/dashboard/page.tsx` — recent-60s uses `weighted_tokens`
- `server/components/ClientManager.tsx` — delete button

**Client — create:**
- `client/VibeCompanion/Tests/` (XCTest target) — `DateParsingTests.swift`, `JsonlTailerTests.swift`, `TokenAggregatorTests.swift`, `ParserTests.swift`, `UsageStoreTests.swift`, `UploaderTests.swift`
- `client/VibeCompanion/Sources/Core/DateParsing.swift`

**Client — modify:**
- `client/Package.swift` — test target
- `client/VibeCompanion/Sources/Collectors/JsonlTailer.swift` — byte-level line splitting
- `client/VibeCompanion/Sources/Collectors/Collector.swift` — use `DateParsing`
- `client/VibeCompanion/Sources/Core/TokenAggregator.swift` — rollover + weighted
- `client/VibeCompanion/Sources/Core/Models.swift` — `weightedTokens`
- `client/VibeCompanion/Sources/Storage/UsageStore.swift` — `recoverStuck()`
- `client/VibeCompanion/Sources/Networking/Uploader.swift` — Transport, status codes, backoff
- `client/VibeCompanion/Sources/Networking/Settings.swift` — clear auth-block on token save (via existing setter)
- `client/VibeCompanion/Sources/Overlay/LottiePetView.swift` — robust resource load

---

## Task 1: Server vitest test harness

**Files:**
- Create: `server/vitest.config.ts`, `server/lib/smoke.test.ts`
- Modify: `server/package.json`

**Interfaces:**
- Produces: `npm test` (== `vitest run`) executes `*.test.ts` under `server/`.

- [ ] **Step 1: Add vitest dependency**

Run (from `server/`): `npm install -D vitest@^2.1.8`

- [ ] **Step 2: Write vitest config**

Create `server/vitest.config.ts`:
```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["lib/**/*.test.ts"],
  },
});
```

- [ ] **Step 3: Add test script + smoke test**

In `server/package.json` `scripts`, add:
```json
"test": "vitest run",
"test:watch": "vitest"
```
Create `server/lib/smoke.test.ts`:
```ts
import { expect, test } from "vitest";
test("vitest runs", () => {
  expect(1 + 1).toBe(2);
});
```

- [ ] **Step 4: Run tests**

Run (from `server/`): `npm test`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add server/package.json server/package-lock.json server/vitest.config.ts server/lib/smoke.test.ts
git commit -m "test: add vitest harness for server"
```

---

## Task 2: Client XCTest target

**Files:**
- Modify: `client/Package.swift`
- Create: `client/VibeCompanion/Tests/SmokeTests.swift`

**Interfaces:**
- Produces: `swift test` runs XCTest with `@testable import VibeCompanion`.

- [ ] **Step 1: Add test target**

In `client/Package.swift`, after the executable target in `targets: [...]`, add:
```swift
        ,
        .testTarget(
            name: "VibeCompanionTests",
            dependencies: ["VibeCompanion"],
            path: "VibeCompanion/Tests"
        )
```

- [ ] **Step 2: Write smoke test**

Create `client/VibeCompanion/Tests/SmokeTests.swift`:
```swift
import XCTest
@testable import VibeCompanion

final class SmokeTests: XCTestCase {
    func testTrue() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 3: Run to verify target compiles/fails appropriately**

Run (from `client/`): `swift test 2>&1 | tail -20`
Expected: compiles and PASS (dependencies download on first run). If `@testable` requires the executable to be importable and it fails, keep the smoke test but confirm the failure is only about missing later symbols — not here.

- [ ] **Step 4: Run tests pass**

Run (from `client/`): `swift test`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add client/Package.swift client/VibeCompanion/Tests/SmokeTests.swift
git commit -m "test: add XCTest target for client"
```

---

## Task 3: H1 — client-token hashing util

**Files:**
- Create: `server/lib/auth/token.ts`, `server/lib/auth/token.test.ts`

**Interfaces:**
- Produces: `hashClientToken(token: string): string` — hex SHA-256, 64 chars.

- [ ] **Step 1: Write failing test**

Create `server/lib/auth/token.test.ts`:
```ts
import { expect, test } from "vitest";
import { hashClientToken } from "./token";

test("deterministic", () => {
  expect(hashClientToken("vc_abc")).toBe(hashClientToken("vc_abc"));
});
test("distinct tokens differ", () => {
  expect(hashClientToken("vc_a")).not.toBe(hashClientToken("vc_b"));
});
test("hex sha256 length 64", () => {
  expect(hashClientToken("vc_abc")).toMatch(/^[0-9a-f]{64}$/);
});
```

- [ ] **Step 2: Run to verify it fails**

Run (from `server/`): `npx vitest run lib/auth/token.test.ts`
Expected: FAIL (cannot find `./token`).

- [ ] **Step 3: Implement**

Create `server/lib/auth/token.ts`:
```ts
import { createHash } from "node:crypto";

// 客户端 token 是高熵随机串，用快哈希（SHA-256）即可，便于唯一索引 O(1) 查询。
export function hashClientToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}
```

- [ ] **Step 4: Run to verify pass**

Run (from `server/`): `npx vitest run lib/auth/token.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add server/lib/auth/token.ts server/lib/auth/token.test.ts
git commit -m "feat(auth): sha256 client-token hashing (H1)"
```

---

## Task 4: H1 — wire O(1) token auth + unique index

**Files:**
- Modify: `server/lib/db/schema.ts`, `server/lib/auth/index.ts`, `server/lib/auth/client.ts`, `server/app/api/clients/register/route.ts`

**Interfaces:**
- Consumes: `hashClientToken` (Task 3).
- Produces: `signClientToken(): { token: string; hash: string }` (no args, sync); `resolveClient` unchanged signature/return.

- [ ] **Step 1: Add unique index to schema**

In `server/lib/db/schema.ts`, in the `clients` table's index callback, add alongside `userIdx`:
```ts
    tokenHashIdx: uniqueIndex("clients_token_hash_idx").on(t.clientTokenHash),
```

- [ ] **Step 2: Update signClientToken**

In `server/lib/auth/index.ts`, replace `signClientToken`/`verifyClientToken` (remove bcrypt for tokens):
```ts
import { hashClientToken } from "./token";

// 长期客户端 token：随机生成，存 SHA-256，明文只返回一次。
export function signClientToken(): { token: string; hash: string } {
  const raw = crypto.randomUUID() + "." + crypto.randomUUID();
  const token = `vc_${raw.replace(/-/g, "")}`;
  return { token, hash: hashClientToken(token) };
}
```
Delete `verifyClientToken`. Keep `hashPassword`/`verifyPassword` (bcrypt) and session functions.

- [ ] **Step 3: Update resolveClient + register call site**

In `server/lib/auth/client.ts`, replace the loop body:
```ts
import { hashClientToken } from "@/lib/auth/token";
// ...
export async function resolveClient(req: NextRequest) {
  const auth = req.headers.get("authorization") ?? "";
  const m = auth.match(/^Bearer\s+(vc_[\w.]+)$/i);
  if (!m) return { ok: false as const, error: "missing_bearer_token" };
  const hash = hashClientToken(m[1]);

  const rows = await db
    .select({
      id: schema.clients.id,
      userId: schema.clients.userId,
      deviceName: schema.clients.deviceName,
    })
    .from(schema.clients)
    .where(eq(schema.clients.clientTokenHash, hash))
    .limit(1);

  const c = rows[0];
  if (!c) return { ok: false as const, error: "invalid_client_token" };

  await db.update(schema.clients).set({ lastSeenAt: Date.now() }).where(eq(schema.clients.id, c.id));
  return { ok: true as const, client: { id: c.id, userId: c.userId, deviceName: c.deviceName } };
}
```
In `server/app/api/clients/register/route.ts:31`, change `const { token, hash } = await signClientToken(id);` to `const { token, hash } = signClientToken();`.

- [ ] **Step 4: Rebuild schema + typecheck + build**

Run (from `server/`): `npm run db:push -- --force && npx tsc --noEmit && npm run build 2>&1 | tail -15`
Expected: db push succeeds; tsc exit 0; build succeeds. (Manual: no unit test — verified by typecheck + build; behavior verified end-to-end in Task 16.)

- [ ] **Step 5: Commit**

```bash
git add server/lib/db/schema.ts server/lib/auth/index.ts server/lib/auth/client.ts server/app/api/clients/register/route.ts
git commit -m "perf(auth): O(1) client-token lookup via unique sha256 index (H1)"
```

---

## Task 5: H2 — AUTH_SECRET fail-hard in production

**Files:**
- Create: `server/lib/auth/secret.ts`, `server/lib/auth/secret.test.ts`
- Modify: `server/lib/auth/index.ts`

**Interfaces:**
- Produces: `assertAuthSecret(env: { AUTH_SECRET?: string; NODE_ENV?: string }): string` — returns secret string or throws.

- [ ] **Step 1: Write failing test**

Create `server/lib/auth/secret.test.ts`:
```ts
import { expect, test } from "vitest";
import { assertAuthSecret } from "./secret";

test("production without secret throws", () => {
  expect(() => assertAuthSecret({ NODE_ENV: "production" })).toThrow();
});
test("production with secret returns it", () => {
  expect(assertAuthSecret({ NODE_ENV: "production", AUTH_SECRET: "s" })).toBe("s");
});
test("dev without secret falls back", () => {
  expect(assertAuthSecret({ NODE_ENV: "development" })).toContain("dev-secret");
});
```

- [ ] **Step 2: Run to verify it fails**

Run (from `server/`): `npx vitest run lib/auth/secret.test.ts`
Expected: FAIL (cannot find `./secret`).

- [ ] **Step 3: Implement**

Create `server/lib/auth/secret.ts`:
```ts
const DEV_FALLBACK = "dev-secret-change-me-in-production";

export function assertAuthSecret(env: { AUTH_SECRET?: string; NODE_ENV?: string }): string {
  if (env.AUTH_SECRET) return env.AUTH_SECRET;
  if (env.NODE_ENV === "production") {
    throw new Error("AUTH_SECRET must be set in production");
  }
  console.warn("[auth] AUTH_SECRET not set — using insecure dev fallback");
  return DEV_FALLBACK;
}
```

- [ ] **Step 4: Run to verify pass, then wire into index.ts**

Run (from `server/`): `npx vitest run lib/auth/secret.test.ts` → PASS.
In `server/lib/auth/index.ts`, replace the top `secret` const:
```ts
import { assertAuthSecret } from "./secret";
const secret = new TextEncoder().encode(assertAuthSecret(process.env));
```
Run: `npx tsc --noEmit` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add server/lib/auth/secret.ts server/lib/auth/secret.test.ts server/lib/auth/index.ts
git commit -m "feat(auth): fail-hard when AUTH_SECRET missing in production (H2)"
```

---

## Task 6: H4 — upload bounds + recordedAt window

**Files:**
- Create: `server/lib/usage/schema.ts`, `server/lib/usage/schema.test.ts`
- Modify: `server/app/api/usage/batch/route.ts`

**Interfaces:**
- Produces: `eventSchema`, `bodySchema` (zod), `MAX_TOKENS = 50_000_000`, `recordedAtInRange(v: number, now: number): boolean`.

- [ ] **Step 1: Write failing test**

Create `server/lib/usage/schema.test.ts`:
```ts
import { expect, test } from "vitest";
import { eventSchema, MAX_TOKENS, recordedAtInRange } from "./schema";

const base = {
  agent: "claude", inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0,
  cacheReadTokens: 0, reasoningTokens: 0, totalTokens: 2,
  recordedAt: Date.now(), sourceUuid: "u1",
};

test("valid event parses", () => {
  expect(eventSchema.safeParse(base).success).toBe(true);
});
test("token over max rejected", () => {
  expect(eventSchema.safeParse({ ...base, inputTokens: MAX_TOKENS + 1 }).success).toBe(false);
});
test("negative token rejected", () => {
  expect(eventSchema.safeParse({ ...base, outputTokens: -1 }).success).toBe(false);
});
test("recordedAt far past rejected", () => {
  expect(eventSchema.safeParse({ ...base, recordedAt: Date.now() - 91 * 86400_000 }).success).toBe(false);
});
test("recordedAt far future rejected", () => {
  expect(eventSchema.safeParse({ ...base, recordedAt: Date.now() + 11 * 60_000 }).success).toBe(false);
});
test("recordedAtInRange boundaries", () => {
  const now = 1_000_000_000_000;
  expect(recordedAtInRange(now, now)).toBe(true);
  expect(recordedAtInRange(now - 90 * 86400_000, now)).toBe(true);
  expect(recordedAtInRange(now - 90 * 86400_000 - 1, now)).toBe(false);
  expect(recordedAtInRange(now + 600_000, now)).toBe(true);
  expect(recordedAtInRange(now + 600_001, now)).toBe(false);
});
```

- [ ] **Step 2: Run to verify it fails**

Run (from `server/`): `npx vitest run lib/usage/schema.test.ts`
Expected: FAIL (cannot find `./schema`).

- [ ] **Step 3: Implement**

Create `server/lib/usage/schema.ts`:
```ts
import { z } from "zod";

export const MAX_TOKENS = 50_000_000;
const PAST_MS = 90 * 86400_000;
const FUTURE_MS = 600_000;

export function recordedAtInRange(v: number, now: number): boolean {
  return v >= now - PAST_MS && v <= now + FUTURE_MS;
}

const tokenField = z.number().int().min(0).max(MAX_TOKENS);

export const eventSchema = z.object({
  agent: z.enum(["claude", "codex"]),
  sessionId: z.string().max(255).nullable().optional(),
  model: z.string().max(255).nullable().optional(),
  inputTokens: tokenField,
  outputTokens: tokenField,
  cacheCreationTokens: tokenField,
  cacheReadTokens: tokenField,
  reasoningTokens: tokenField,
  totalTokens: tokenField,
  recordedAt: z.number().int().refine((v) => recordedAtInRange(v, Date.now()), "recordedAt out of range"),
  sourceUuid: z.string().min(1).max(255),
});

export const bodySchema = z.object({
  events: z.array(eventSchema).min(1).max(500),
});
```

- [ ] **Step 4: Run to verify pass, then wire batch route**

Run (from `server/`): `npx vitest run lib/usage/schema.test.ts` → PASS (6 tests).
In `server/app/api/usage/batch/route.ts`, delete the inline `eventSchema`/`bodySchema` and import: `import { bodySchema } from "@/lib/usage/schema";`. Run `npx tsc --noEmit` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add server/lib/usage/schema.ts server/lib/usage/schema.test.ts server/app/api/usage/batch/route.ts
git commit -m "feat(usage): bound token fields + recordedAt window (H4)"
```

---

## Task 7: M7 — weighted tokens (server)

**Files:**
- Create: `server/lib/usage/weighted.test.ts`
- Modify: `server/lib/usage/types.ts`, `server/lib/db/schema.ts`, `server/app/api/usage/batch/route.ts`, `server/lib/usage/queries.ts`, `server/app/api/usage/me/route.ts`, `server/app/dashboard/page.tsx`

**Interfaces:**
- Produces: `weightedTokens(e: { inputTokens; outputTokens; cacheCreationTokens; reasoningTokens }): number`; `usage_events.weightedTokens` column; leaderboard/daily/recent aggregate on `weighted_tokens`.

- [ ] **Step 1: Write failing test**

Create `server/lib/usage/weighted.test.ts`:
```ts
import { expect, test } from "vitest";
import { weightedTokens } from "./types";

test("excludes cacheRead", () => {
  expect(weightedTokens({ inputTokens: 10, outputTokens: 20, cacheCreationTokens: 5, cacheReadTokens: 9999, reasoningTokens: 3 })).toBe(38);
});
test("zero", () => {
  expect(weightedTokens({ inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0 })).toBe(0);
});
```

- [ ] **Step 2: Run to verify it fails**

Run (from `server/`): `npx vitest run lib/usage/weighted.test.ts`
Expected: FAIL (no `weightedTokens` export).

- [ ] **Step 3: Implement helper + column**

In `server/lib/usage/types.ts`, add:
```ts
export function weightedTokens(e: {
  inputTokens: number; outputTokens: number; cacheCreationTokens: number; reasoningTokens: number;
}): number {
  return e.inputTokens + e.outputTokens + e.cacheCreationTokens + e.reasoningTokens;
}
```
In `server/lib/db/schema.ts` `usageEvents`, add after `totalTokens`:
```ts
    weightedTokens: integer("weighted_tokens").notNull().default(0),
```

- [ ] **Step 4: Run helper test pass, then wire insert + queries**

Run (from `server/`): `npx vitest run lib/usage/weighted.test.ts` → PASS.

In `server/app/api/usage/batch/route.ts`, import `weightedTokens` and in the insert `.values({...})` add `weightedTokens: weightedTokens(e),`.

In `server/lib/usage/queries.ts`:
- `dailyTotalsForUser`: add to select `weightedTokens: sql<number>\`SUM(${schema.usageEvents.weightedTokens})\`.as("weighted_tokens")`, add to `DailyTotal` interface `weightedTokens: number;` and to the mapped return `weightedTokens: Number(r.weightedTokens ?? 0),`.
- `globalLeaderboard`: change `totalTokens` select to `sql<number>\`SUM(${schema.usageEvents.weightedTokens})\`.as("total_tokens")` and `orderBy(desc(sql\`total_tokens\`))` (name unchanged; value now weighted).

In `server/app/api/usage/me/route.ts` and `server/app/dashboard/page.tsx`, change the recent-60s `SUM(${schema.usageEvents.totalTokens})` to `SUM(${schema.usageEvents.weightedTokens})`. In dashboard, the week/today stat + bar chart use `d.totalTokens`; switch those to `d.weightedTokens` for consistency (`weekTotal`, `maxBar`, bar `height`, `todayRow?.weightedTokens`, tooltip).

Run: `npm run db:push -- --force && npx tsc --noEmit && npm run build 2>&1 | tail -15` → all succeed.

- [ ] **Step 5: Commit**

```bash
git add server/lib/usage/types.ts server/lib/usage/weighted.test.ts server/lib/db/schema.ts server/app/api/usage/batch/route.ts server/lib/usage/queries.ts server/app/api/usage/me/route.ts server/app/dashboard/page.tsx
git commit -m "feat(usage): weighted-token rate/leaderboard excluding cacheRead (M7)"
```

---

## Task 8: M6 — device deletion endpoint + UI

**Files:**
- Create: `server/app/api/clients/[id]/route.ts`
- Modify: `server/components/ClientManager.tsx`, `client/VibeCompanion/Sources/Settings/SettingsView.swift`

**Interfaces:**
- Produces: `DELETE /api/clients/:id` → `{ ok: true }` (200) | `{ error }` (401/404).

- [ ] **Step 1: Implement DELETE route**

Create `server/app/api/clients/[id]/route.ts`:
```ts
import { NextResponse } from "next/server";
import { requireUser } from "@/lib/auth/session";
import { db, schema } from "@/lib/db";
import { and, eq } from "drizzle-orm";

export async function DELETE(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  let user;
  try {
    user = await requireUser();
  } catch {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  const { id } = await params;
  const rows = await db
    .select({ id: schema.clients.id })
    .from(schema.clients)
    .where(and(eq(schema.clients.id, id), eq(schema.clients.userId, user.id)))
    .limit(1);
  if (!rows[0]) return NextResponse.json({ error: "not_found" }, { status: 404 });
  await db.delete(schema.clients).where(eq(schema.clients.id, id));
  return NextResponse.json({ ok: true });
}
```

- [ ] **Step 2: Verify typecheck/build**

Run (from `server/`): `npx tsc --noEmit && npm run build 2>&1 | tail -8`
Expected: exit 0 / build ok. (No unit test — ownership logic is a DB where-clause; verified end-to-end in Task 16.)

- [ ] **Step 3: Wire ClientManager delete button**

In `server/components/ClientManager.tsx`, add inside the component:
```tsx
  async function removeDevice(id: string) {
    if (!confirm("删除该设备将一并清除其历史用量，确认？")) return;
    const res = await fetch(`/api/clients/${id}`, { method: "DELETE" });
    if (res.ok) setClients((prev) => prev.filter((c) => c.id !== id));
    else setError("删除失败");
  }
```
In the device `<li>`, add before the status dot:
```tsx
            <button onClick={() => removeDevice(c.id)} className="mr-2 text-xs text-red-500 hover:underline">删除</button>
```

- [ ] **Step 4: Clarify client copy**

In `client/VibeCompanion/Sources/Settings/SettingsView.swift`, change the destructive button title/label copy to `"登出此设备（仅本机）"` and add a caption below it: `Text("如需彻底吊销 token，请在网站 Dashboard 删除该设备。").font(.caption).foregroundColor(.secondary)`.
Run (from `server/`): `npm run build 2>&1 | tail -5` → ok.

- [ ] **Step 5: Commit**

```bash
git add server/app/api/clients/ server/components/ClientManager.tsx client/VibeCompanion/Sources/Settings/SettingsView.swift
git commit -m "feat(clients): device deletion endpoint + UI (M6)"
```

---

## Task 9: M3 — ISO8601 fractional-seconds parsing

**Files:**
- Create: `client/VibeCompanion/Sources/Core/DateParsing.swift`, `client/VibeCompanion/Tests/DateParsingTests.swift`
- Modify: `client/VibeCompanion/Sources/Collectors/Collector.swift`

**Interfaces:**
- Produces: `enum DateParsing { static func parseISO8601(_ s: String) -> Date? }`.

- [ ] **Step 1: Write failing test**

Create `client/VibeCompanion/Tests/DateParsingTests.swift`:
```swift
import XCTest
@testable import VibeCompanion

final class DateParsingTests: XCTestCase {
    func testFractionalSeconds() {
        let d = DateParsing.parseISO8601("2026-07-25T09:30:00.123Z")
        XCTAssertNotNil(d)
        XCTAssertEqual(Int64(d!.timeIntervalSince1970 * 1000), 1_784_971_800_123)
    }
    func testNoFractional() {
        XCTAssertNotNil(DateParsing.parseISO8601("2026-07-25T09:30:00Z"))
    }
    func testInvalid() {
        XCTAssertNil(DateParsing.parseISO8601("not-a-date"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `client/`): `swift test --filter DateParsingTests 2>&1 | tail -15`
Expected: FAIL (no `DateParsing`).

- [ ] **Step 3: Implement**

Create `client/VibeCompanion/Sources/Core/DateParsing.swift`:
```swift
import Foundation

enum DateParsing {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO8601(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }
}
```

- [ ] **Step 4: Run to verify pass, then wire Collector**

Run (from `client/`): `swift test --filter DateParsingTests` → PASS.
In `client/VibeCompanion/Sources/Collectors/Collector.swift`, replace both `ISO8601DateFormatter().date(from: ts)` occurrences with `DateParsing.parseISO8601(ts)`.
Run: `swift build` → success.

- [ ] **Step 5: Commit**

```bash
git add client/VibeCompanion/Sources/Core/DateParsing.swift client/VibeCompanion/Tests/DateParsingTests.swift client/VibeCompanion/Sources/Collectors/Collector.swift
git commit -m "fix(collector): parse ISO8601 fractional seconds (M3)"
```

---

## Task 10: M4 — byte-level line splitting in JsonlTailer

**Files:**
- Modify: `client/VibeCompanion/Sources/Collectors/JsonlTailer.swift`
- Create: `client/VibeCompanion/Tests/JsonlTailerTests.swift`

**Interfaces:**
- Produces: `enum LineSplitter { static func split(_ buffer: Data) -> (lines: [Data], rest: Data) }` (internal, in JsonlTailer.swift).

- [ ] **Step 1: Write failing test**

Create `client/VibeCompanion/Tests/JsonlTailerTests.swift`:
```swift
import XCTest
@testable import VibeCompanion

final class JsonlTailerTests: XCTestCase {
    func testCompleteLines() {
        let (lines, rest) = LineSplitter.split(Data("a\nb\n".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["a", "b"])
        XCTAssertEqual(rest.count, 0)
    }
    func testTrailingPartialKept() {
        let (lines, rest) = LineSplitter.split(Data("a\nb".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["a"])
        XCTAssertEqual(String(data: rest, encoding: .utf8), "b")
    }
    func testMultibyteAcrossSplit() {
        // "你好" split mid-byte: first chunk ends inside the character.
        let full = Data("x\n你好".utf8)
        let cut = full.count - 1
        let (l1, r1) = LineSplitter.split(full.prefix(cut))
        let (l2, r2) = LineSplitter.split(r1 + full.suffix(from: cut))
        let all = (l1 + l2).compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(all, ["x"])
        XCTAssertEqual(String(data: r2, encoding: .utf8), "你好")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `client/`): `swift test --filter JsonlTailerTests 2>&1 | tail -15`
Expected: FAIL (no `LineSplitter`).

- [ ] **Step 3: Implement splitter + use it**

In `client/VibeCompanion/Sources/Collectors/JsonlTailer.swift`, add at file scope:
```swift
enum LineSplitter {
    static func split(_ buffer: Data) -> (lines: [Data], rest: Data) {
        let nl = UInt8(ascii: "\n")
        var lines: [Data] = []
        var start = buffer.startIndex
        var i = buffer.startIndex
        while i < buffer.endIndex {
            if buffer[i] == nl {
                if i > start { lines.append(buffer.subdata(in: start..<i)) }
                start = buffer.index(after: i)
            }
            i = buffer.index(after: i)
        }
        return (lines, buffer.subdata(in: start..<buffer.endIndex))
    }
}
```
Add `private var partials: [URL: Data] = [:]` to `JsonlTailer`. Replace the tail of `readNew` (from `let data = Data(...)` onward) with:
```swift
        let data = Data(bytes: buffer, count: Int(read))
        offsets[url] = currentSize

        let combined = (partials[url] ?? Data()) + data
        let (lines, rest) = LineSplitter.split(combined)
        partials[url] = rest
        for line in lines {
            if let text = String(data: line, encoding: .utf8) {
                onLine?(url, text)
            }
        }
    }
```
In the rotation branch (`if offset > currentSize { offset = 0 }`), also add `partials[url] = Data()`.

- [ ] **Step 4: Run to verify pass**

Run (from `client/`): `swift test --filter JsonlTailerTests` → PASS (3 tests). Then `swift build` → success.

- [ ] **Step 5: Commit**

```bash
git add client/VibeCompanion/Sources/Collectors/JsonlTailer.swift client/VibeCompanion/Tests/JsonlTailerTests.swift
git commit -m "fix(tailer): byte-level line split, keep partial/multibyte remainder (M4)"
```

---

## Task 11: M1 — TokenAggregator midnight rollover + weighted (M7 client)

**Files:**
- Modify: `client/VibeCompanion/Sources/Core/Models.swift`, `client/VibeCompanion/Sources/Core/TokenAggregator.swift`
- Create: `client/VibeCompanion/Tests/TokenAggregatorTests.swift`

**Interfaces:**
- Consumes: `UsageEvent`.
- Produces: `UsageEvent.weightedTokens: Int` (computed); `TokenAggregator` gains injectable clock/calendar and rolls `todayTotal` to 0 across days; rate uses `weightedTokens`.

- [ ] **Step 1: Write failing test**

Create `client/VibeCompanion/Tests/TokenAggregatorTests.swift`:
```swift
import XCTest
@testable import VibeCompanion

@MainActor
final class TokenAggregatorTests: XCTestCase {
    private func ev(total: Int, weightedInput: Int, at ms: Int64) -> UsageEvent {
        UsageEvent(sourceUuid: "u\(ms)", agent: "claude", sessionId: nil, model: nil,
                   inputTokens: weightedInput, outputTokens: 0, cacheCreationTokens: 0,
                   cacheReadTokens: total - weightedInput, reasoningTokens: 0,
                   totalTokens: total, recordedAt: ms)
    }

    func testWeightedExcludesCacheRead() {
        XCTAssertEqual(ev(total: 100, weightedInput: 10, at: 0).weightedTokens, 10)
    }

    func testTodayResetsAcrossDay() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let agg = TokenAggregator(windowSeconds: 60, now: { now })
        agg.ingest(ev(total: 50, weightedInput: 50, at: Int64(now.timeIntervalSince1970 * 1000)))
        XCTAssertEqual(agg.todayTotal, 50)
        now = now.addingTimeInterval(86_400)   // next day
        agg.ingest(ev(total: 20, weightedInput: 20, at: Int64(now.timeIntervalSince1970 * 1000)))
        XCTAssertEqual(agg.todayTotal, 20)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `client/`): `swift test --filter TokenAggregatorTests 2>&1 | tail -15`
Expected: FAIL (no `weightedTokens`; `init(windowSeconds:now:)` missing).

- [ ] **Step 3: Implement**

In `client/VibeCompanion/Sources/Core/Models.swift`, add to `UsageEvent`:
```swift
    var weightedTokens: Int { inputTokens + outputTokens + cacheCreationTokens + reasoningTokens }
```
In `client/VibeCompanion/Sources/Core/TokenAggregator.swift`:
- Add `private let now: () -> Date` and `private var currentDayKey: String`.
- Change init to `init(windowSeconds: TimeInterval = AppConfig.rateWindowSeconds, now: @escaping () -> Date = { Date() })`, set `self.now = now`, `self.currentDayKey = TokenAggregator.dayKey(now())`.
- Add:
```swift
    private static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }
    private func rolloverIfNeeded() {
        let k = TokenAggregator.dayKey(now())
        if k != currentDayKey { currentDayKey = k; todayTotal = 0 }
    }
```
- In `ingest`, first line `rolloverIfNeeded()`; use `event.weightedTokens` for both the window sample and the `todayTotal +=`; replace the today check to compare event day to current day key:
```swift
    func ingest(_ event: UsageEvent) {
        rolloverIfNeeded()
        let t = now()
        window.append(Sample(timestamp: t, tokens: event.weightedTokens))
        let eventDay = TokenAggregator.dayKey(Date(timeIntervalSince1970: TimeInterval(event.recordedAt) / 1000))
        if eventDay == currentDayKey { todayTotal += event.weightedTokens }
        recompute(now: t)
    }
```
- In `evict`, first line `rolloverIfNeeded()`; use `now()` instead of `Date()`.

- [ ] **Step 4: Run to verify pass**

Run (from `client/`): `swift test --filter TokenAggregatorTests` → PASS. Then `swift build` → success.

- [ ] **Step 5: Commit**

```bash
git add client/VibeCompanion/Sources/Core/Models.swift client/VibeCompanion/Sources/Core/TokenAggregator.swift client/VibeCompanion/Tests/TokenAggregatorTests.swift
git commit -m "fix(aggregator): midnight rollover + weighted-token rate (M1, M7)"
```

---

## Task 12: Parser regression tests

**Files:**
- Create: `client/VibeCompanion/Tests/ParserTests.swift`

**Interfaces:**
- Consumes: `ClaudeParser.parse`, `CodexParser.parse` (must be `internal` — verify they are not `private`; the enums are top-level `internal` already).

- [ ] **Step 1: Write test**

Create `client/VibeCompanion/Tests/ParserTests.swift`:
```swift
import XCTest
@testable import VibeCompanion

final class ParserTests: XCTestCase {
    func testClaudeAssistant() {
        let obj: [String: Any] = [
            "type": "assistant", "uuid": "abc", "sessionId": "s1",
            "timestamp": "2026-07-25T09:30:00.000Z",
            "message": ["model": "claude-opus-4-8",
                        "usage": ["input_tokens": 10, "output_tokens": 20,
                                  "cache_creation_input_tokens": 5, "cache_read_input_tokens": 100]],
        ]
        let ev = ClaudeParser.parse(obj)
        XCTAssertEqual(ev?.sourceUuid, "abc")
        XCTAssertEqual(ev?.totalTokens, 135)
        XCTAssertEqual(ev?.weightedTokens, 35)
    }
    func testClaudeIgnoresNonAssistant() {
        XCTAssertNil(ClaudeParser.parse(["type": "user"]))
    }
    func testCodexTokenCount() {
        let obj: [String: Any] = [
            "timestamp": "2026-07-25T09:30:00Z",
            "payload": ["type": "token_count", "session_id": "cs1",
                        "info": ["model": "gpt-5",
                                 "last_token_usage": ["input_tokens": 1, "cached_input_tokens": 2,
                                                      "output_tokens": 3, "reasoning_output_tokens": 4,
                                                      "total_tokens": 10]]],
        ]
        let ev = CodexParser.parse(obj)
        XCTAssertEqual(ev?.agent, "codex")
        XCTAssertEqual(ev?.totalTokens, 10)
        XCTAssertEqual(ev?.cacheReadTokens, 2)
    }
}
```

- [ ] **Step 2: Run to verify (fails if parsers private, else passes)**

Run (from `client/`): `swift test --filter ParserTests 2>&1 | tail -15`
Expected: PASS. If it fails to compile because `ClaudeParser`/`CodexParser` are inaccessible, they are already top-level `internal` in `Collector.swift` — no change needed; investigate any real failure.

- [ ] **Step 3: (only if needed) adjust visibility**

If access failed, ensure `enum ClaudeParser`/`enum CodexParser` and their `static func parse` are not marked `private`. (Baseline: they are `internal` — expect no change.)

- [ ] **Step 4: Confirm pass**

Run (from `client/`): `swift test --filter ParserTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add client/VibeCompanion/Tests/ParserTests.swift
git commit -m "test(collector): Claude/Codex parser coverage"
```

---

## Task 13: H3 — UsageStore stuck-row recovery

**Files:**
- Modify: `client/VibeCompanion/Sources/Storage/UsageStore.swift`
- Create: `client/VibeCompanion/Tests/UsageStoreTests.swift`

**Interfaces:**
- Produces: `UsageStore.recoverStuck()` (internal); called from `init` after `migrator.migrate`. Add `init(path: String)` test hook.

- [ ] **Step 1: Write failing test**

Create `client/VibeCompanion/Tests/UsageStoreTests.swift`:
```swift
import XCTest
import GRDB
@testable import VibeCompanion

final class UsageStoreTests: XCTestCase {
    func testRecoverStuckRequeues() throws {
        let tmp = NSTemporaryDirectory() + "vc-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = try UsageStore(path: tmp)
        try store.enqueue(UsageEvent(sourceUuid: "u1", agent: "claude", sessionId: nil, model: nil,
            inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0,
            reasoningTokens: 0, totalTokens: 2, recordedAt: 1))
        _ = try store.fetchPending(limit: 10)             // marks it 'uploading'
        XCTAssertEqual(try store.pendingCount(), 0)

        let reopened = try UsageStore(path: tmp)           // init runs recoverStuck
        XCTAssertEqual(try reopened.pendingCount(), 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `client/`): `swift test --filter UsageStoreTests 2>&1 | tail -15`
Expected: FAIL (no `init(path:)`, or count is 0 after reopen).

- [ ] **Step 3: Implement**

In `client/VibeCompanion/Sources/Storage/UsageStore.swift`, refactor `init` to delegate:
```swift
    convenience init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("VibeCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try self.init(path: dir.appendingPathComponent("usage.db").path)
    }

    init(path: String) throws {
        dbPool = try DatabasePool(path: path)
        try migrator.migrate(dbPool)
        try recoverStuck()
    }

    // 崩溃后复位卡在 uploading 的行，避免永久卡死丢数据。
    func recoverStuck() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE pending_event SET status='pending' WHERE status='uploading'")
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run (from `client/`): `swift test --filter UsageStoreTests` → PASS. Then `swift build` → success.

- [ ] **Step 5: Commit**

```bash
git add client/VibeCompanion/Sources/Storage/UsageStore.swift client/VibeCompanion/Tests/UsageStoreTests.swift
git commit -m "fix(store): requeue stuck 'uploading' rows on startup (H3)"
```

---

## Task 14: M2 — Uploader status codes, auth-block, backoff

**Files:**
- Modify: `client/VibeCompanion/Sources/Networking/Uploader.swift`
- Create: `client/VibeCompanion/Tests/UploaderTests.swift`

**Interfaces:**
- Produces: `protocol Transport { func send(_ req: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) }`; `Uploader(store:transport:now:)`; `Uploader.nextRetryAt`, `.authBlocked` (internal, testable). On 401/403 → stop + `authBlocked=true`. Transient failure → exponential backoff via `attempts`.

- [ ] **Step 1: Write failing test**

Create `client/VibeCompanion/Tests/UploaderTests.swift`:
```swift
import XCTest
@testable import VibeCompanion

final class FakeTransport: Transport {
    var status: Int = 200
    var body: Data = Data(#"{"ok":true,"inserted":1,"duplicates":0}"#.utf8)
    var calls = 0
    func send(_ req: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        calls += 1
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)
        completion(body, resp, nil)
    }
}

final class UploaderTests: XCTestCase {
    func testAuthFailureBlocks() throws {
        Settings.shared.clientToken = "vc_test"; Settings.shared.isPaused = false
        let store = try UsageStore(path: NSTemporaryDirectory() + "up-\(UUID().uuidString).db")
        try store.enqueue(UsageEvent(sourceUuid: "u1", agent: "claude", sessionId: nil, model: nil,
            inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
            reasoningTokens: 0, totalTokens: 1, recordedAt: 1))
        let t = FakeTransport(); t.status = 401
        let up = Uploader(store: store, transport: t, now: { Date() })
        up.flush()
        XCTAssertTrue(up.authBlocked)
        XCTAssertEqual(try store.pendingCount(), 1)   // data preserved
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `client/`): `swift test --filter UploaderTests 2>&1 | tail -15`
Expected: FAIL (no `Transport`/new init/`authBlocked`).

- [ ] **Step 3: Implement**

In `client/VibeCompanion/Sources/Networking/Uploader.swift`:
- Add at file scope:
```swift
protocol Transport {
    func send(_ req: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void)
}
extension URLSession: Transport {
    func send(_ req: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        dataTask(with: req, completionHandler: completion).resume()
    }
}
```
- Replace stored `session` with `transport`, add `now`, `authBlocked`, `nextRetryAt`:
```swift
    private let transport: Transport
    private let now: () -> Date
    private(set) var authBlocked = false
    private(set) var nextRetryAt: Date?

    init(store: UsageStore, transport: Transport? = nil, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        if let transport {
            self.transport = transport
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60
            self.transport = URLSession(configuration: cfg)
        }
    }
```
- In `flush()`, after the registered/paused guard add: `guard !authBlocked else { return }` and `if let r = nextRetryAt, now() < r { return }`.
- Change `upload(events:)` to use `transport.send` and inspect status:
```swift
        transport.send(req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                completion(.failure(NSError(domain: "vc.auth", code: code)))
                return
            }
            guard (200..<300).contains(code), let data = data,
                  let resp = try? JSONDecoder().decode(UsageBatchResponse.self, from: data) else {
                completion(.failure(NSError(domain: "vc", code: code, userInfo: [NSLocalizedDescriptionKey: "上传失败(\(code))"])))
                return
            }
            completion(.success(resp))
        }
```
- In `flush`'s result handling, on `.success` set `nextRetryAt = nil`; on `.failure`, if the error domain is `vc.auth`: `authBlocked = true; timer?.invalidate()` and set status `.failed("认证失败，请重新注册")`; else compute backoff: read max `attempts` of this batch (pass a representative attempt count — use `pending.map { $0.attempts }.max() ?? 0` after adding `attempts` to `PendingEvent`) and set `nextRetryAt = now().addingTimeInterval(min(pow(2, Double(attempts)) * 5, 300))`.

Add `let attempts: Int` to `PendingEvent` (read `row["attempts"]`) so backoff can scale.

- [ ] **Step 4: Run to verify pass**

Run (from `client/`): `swift test --filter UploaderTests` → PASS. Then `swift build` → success. Also confirm `AppCoordinator` still compiles (it calls `Uploader(store:)` — the new params are defaulted).

- [ ] **Step 5: Commit**

```bash
git add client/VibeCompanion/Sources/Networking/Uploader.swift client/VibeCompanion/Sources/Storage/UsageStore.swift client/VibeCompanion/Tests/UploaderTests.swift
git commit -m "fix(uploader): handle status codes, block on 401, backoff transient (M2)"
```

---

## Task 15: M5 — robust Lottie resource loading

**Files:**
- Modify: `client/VibeCompanion/Sources/Overlay/LottiePetView.swift`

**Interfaces:**
- Produces: `LottiePetView` that loads `cycling_pet.json` from `Bundle.main/Animations/` with fallback, degrading to nothing (parent shows emoji) if absent.

- [ ] **Step 1: Implement robust loader**

In `client/VibeCompanion/Sources/Overlay/LottiePetView.swift`, change `makeNSView`:
```swift
    func makeNSView(context: Context) -> Lottie.LottieAnimationView {
        let view: LottieAnimationView
        if let url = Bundle.main.url(forResource: animationName, withExtension: "json", subdirectory: "Animations"),
           let anim = LottieAnimation.filepath(url.path) {
            view = LottieAnimationView(animation: anim)
        } else {
            view = LottieAnimationView(name: animationName, bundle: .main)
        }
        view.contentMode = .scaleAspectFit
        view.loopMode = .loop
        view.backgroundBehavior = .pauseAndRestore
        view.animationSpeed = speed
        view.play()
        return view
    }
```

- [ ] **Step 2: Build**

Run (from `client/`): `swift build`
Expected: success (verify `LottieAnimation.filepath` API exists in Lottie 4.5; if named differently, use `LottieAnimation.loadedFrom(url:)` per installed version — confirm via `grep -r "public static func" .build/checkouts/lottie-ios/Sources/**/LottieAnimation*.swift`).

- [ ] **Step 3: Package the app**

Run (from worktree root): `./scripts/build-app.sh`
Expected: `.app` bundle built with `Contents/Resources/Animations/cycling_pet.json`.

- [ ] **Step 4: Manual runtime verification**

Run: `open client/.build/app/VibeCompanion.app`, generate some Claude/Codex usage (or observe idle→active), and confirm the floating pet renders the cycling animation (not blank) when rate > 0.
Expected: animation visible. ⚠️ This is the one finding that unit tests cannot cover — must be confirmed by eye.

- [ ] **Step 5: Commit**

```bash
git add client/VibeCompanion/Sources/Overlay/LottiePetView.swift
git commit -m "fix(overlay): robust Lottie resource lookup with fallback (M5)"
```

---

## Task 16: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Server suite**

Run (from `server/`): `npm test && npx tsc --noEmit && npm run build 2>&1 | tail -8`
Expected: all tests pass, tsc 0, build ok.

- [ ] **Step 2: Client suite**

Run (from `client/`): `swift test 2>&1 | tail -20 && swift build`
Expected: all XCTest pass, build ok.

- [ ] **Step 3: End-to-end smoke (server running)**

Run (from `server/`): `npm run db:push -- --force`, start `npm run dev`, then: register a user, add a device (get token), `curl -X POST localhost:3000/api/usage/batch -H "Authorization: Bearer <token>" -H "Content-Type: application/json" -d '{"events":[{"agent":"claude","inputTokens":10,"outputTokens":20,"cacheCreationTokens":0,"cacheReadTokens":1000,"reasoningTokens":0,"totalTokens":1030,"recordedAt":<now-ms>,"sourceUuid":"e2e-1"}]}'` → `{ok:true,inserted:1}`; verify leaderboard shows weighted 30 (not 1030); delete the device via UI and confirm it disappears; retry the same token after delete → 401.
Expected: all behaviors as described.

- [ ] **Step 4: Commit any fixups, then hand off to review**

```bash
git add -A && git commit -m "chore: verification fixups" --allow-empty
```
Proceed to superpowers:requesting-code-review.
