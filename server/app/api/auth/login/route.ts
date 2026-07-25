import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { db, schema } from "@/lib/db";
import { verifyPassword, signSession, SESSION_COOKIE } from "@/lib/auth";
import { eq } from "drizzle-orm";

const body = z.object({
  email: z.string().email().max(255),
  password: z.string().min(1).max(100),
});

export async function POST(req: NextRequest) {
  let parsed;
  try {
    parsed = body.parse(await req.json());
  } catch {
    return NextResponse.json({ error: "invalid_body" }, { status: 400 });
  }

  const user = (
    await db
      .select()
      .from(schema.users)
      .where(eq(schema.users.email, parsed.email.toLowerCase()))
      .limit(1)
  )[0];
  if (!user || !(await verifyPassword(parsed.password, user.passwordHash))) {
    return NextResponse.json({ error: "invalid_credentials" }, { status: 401 });
  }

  const token = await signSession(user.id);
  const res = NextResponse.json({ ok: true, userId: user.id });
  res.cookies.set(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });
  return res;
}
