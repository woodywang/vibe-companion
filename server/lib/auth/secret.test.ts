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
