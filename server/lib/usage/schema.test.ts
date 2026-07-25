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
