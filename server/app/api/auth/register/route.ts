import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { db, schema } from "@/lib/db";
import { hashPassword, signSession, SESSION_COOKIE } from "@/lib/auth";
import { nanoid } from "nanoid";
import { eq } from "drizzle-orm";

const body = z.object({
  email: z.string().email().max(255),
  password: z.string().min(6).max(100),
  displayName: z.string().min(1).max(64),
});

export async function POST(req: NextRequest) {
  let parsed;
  try {
    parsed = body.parse(await req.json());
  } catch (e) {
    return NextResponse.json({ error: "invalid_body" }, { status: 400 });
  }

  const existing = await db
    .select({ id: schema.users.id })
    .from(schema.users)
    .where(eq(schema.users.email, parsed.email.toLowerCase()))
    .limit(1);
  if (existing.length) {
    return NextResponse.json({ error: "email_taken" }, { status: 409 });
  }

  const id = nanoid();
  const passwordHash = await hashPassword(parsed.password);
  await db.insert(schema.users)
    .values({
      id,
      email: parsed.email.toLowerCase(),
      passwordHash,
      displayName: parsed.displayName.trim(),
    });

  const token = await signSession(id);
  const res = NextResponse.json({ ok: true, userId: id });
  res.cookies.set(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });
  return res;
}
