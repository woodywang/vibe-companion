import { expect, test } from "vitest";
import { weightedTokens } from "./types";

test("excludes cacheRead", () => {
  expect(weightedTokens({ inputTokens: 10, outputTokens: 20, cacheCreationTokens: 5, cacheReadTokens: 9999, reasoningTokens: 3 })).toBe(38);
});
test("zero", () => {
  expect(weightedTokens({ inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0 })).toBe(0);
});
