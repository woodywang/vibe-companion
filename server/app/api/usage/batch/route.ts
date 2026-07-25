import { NextRequest } from "next/server";
import { z } from "zod";
import { db, schema } from "@/lib/db";
import { resolveClient, jsonError } from "@/lib/auth/client";
import { estimateCost, UsageEventInput } from "@/lib/usage/types";
import { nanoid } from "nanoid";

const eventSchema = z.object({
  agent: z.enum(["claude", "codex"]),
  sessionId: z.string().max(255).nullable().optional(),
  model: z.string().max(255).nullable().optional(),
  inputTokens: z.number().int().min(0),
  outputTokens: z.number().int().min(0),
  cacheCreationTokens: z.number().int().min(0),
  cacheReadTokens: z.number().int().min(0),
  reasoningTokens: z.number().int().min(0),
  totalTokens: z.number().int().min(0),
  recordedAt: z.number().int(),
  sourceUuid: z.string().min(1).max(255),
});

const bodySchema = z.object({
  events: z.array(eventSchema).min(1).max(500),
});

export async function POST(req: NextRequest) {
  const resolved = await resolveClient(req);
  if (!resolved.ok) {
    return jsonError(401, resolved.error);
  }
  const client = resolved.client;

  let parsed;
  try {
    parsed = bodySchema.parse(await req.json());
  } catch {
    return jsonError(400, "invalid_body");
  }

  let inserted = 0;
  let duplicates = 0;

  // 逐条插入，靠 UNIQUE(client_id, source_uuid) 保证幂等
  // libsql 支持事务，包裹以提升批量性能
  await db.transaction(async (tx) => {
    for (const e of parsed.events) {
      const cost = estimateCost(e.model, e satisfies UsageEventInput);
      try {
        await tx.insert(schema.usageEvents).values({
          id: nanoid(),
          clientId: client.id,
          userId: client.userId,
          agent: e.agent,
          sessionId: e.sessionId ?? null,
          model: e.model ?? null,
          inputTokens: e.inputTokens,
          outputTokens: e.outputTokens,
          cacheCreationTokens: e.cacheCreationTokens,
          cacheReadTokens: e.cacheReadTokens,
          reasoningTokens: e.reasoningTokens,
          totalTokens: e.totalTokens,
          costUsd: cost,
          recordedAt: e.recordedAt,
          sourceUuid: e.sourceUuid,
        });
        inserted++;
      } catch (err: unknown) {
        // SQLITE_CONSTRAINT_UNIQUE -> 已存在，跳过
        const msg = (err as { message?: string })?.message ?? "";
        if (msg.includes("UNIQUE") || msg.includes("constraint")) {
          duplicates++;
        } else {
          throw err;
        }
      }
    }
  });

  return Response.json({ ok: true, inserted, duplicates });
}
