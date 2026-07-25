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
