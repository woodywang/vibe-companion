import { NextRequest } from "next/server";
import { db, schema } from "@/lib/db";
import { resolveClient, jsonError } from "@/lib/auth/client";
import { estimateCost, weightedTokens, UsageEventInput } from "@/lib/usage/types";
import { bodySchema } from "@/lib/usage/schema";
import { nanoid } from "nanoid";

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
          weightedTokens: weightedTokens(e),
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
