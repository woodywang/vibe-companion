import { expect, test } from "vitest";
import { signSession, verifySession, SESSION_COOKIE } from "./edge";

test("cookie name", () => {
  expect(SESSION_COOKIE).toBe("vc_session");
});
test("sign then verify round-trips the user id", async () => {
  const token = await signSession("user-123");
  const payload = await verifySession(token);
  expect(payload?.sub).toBe("user-123");
});
test("garbage token verifies to null", async () => {
  expect(await verifySession("not.a.jwt")).toBeNull();
});
