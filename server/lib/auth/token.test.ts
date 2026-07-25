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
