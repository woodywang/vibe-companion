// 客户端上传的用量事件结构（与客户端 Swift 结构对应）
export interface UsageEventInput {
  agent: "claude" | "codex";
  sessionId?: string | null;
  model?: string | null;
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
  reasoningTokens: number;
  totalTokens: number;
  recordedAt: number; // ms epoch
  sourceUuid: string; // 客户端去重键
}

export interface UsageBatchInput {
  events: UsageEventInput[];
}

// 加权 token：排除 cacheRead（体量大、成本低，会淹没速率/排行榜）
// cacheReadTokens 可选出现在入参形状中（调用方常传入完整 usage 事件），但从不参与计算。
export function weightedTokens(e: {
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens?: number;
  reasoningTokens: number;
}): number {
  return e.inputTokens + e.outputTokens + e.cacheCreationTokens + e.reasoningTokens;
}

export interface UsageBatchResult {
  inserted: number;
  duplicates: number;
}

// ── 成本估算（简化定价表，USD per 1M tokens）─────────────────────────
// MVP 用粗略定价；后续可细化。返回 0 表示未知模型。
interface Price {
  input: number;
  output: number;
  cacheCreation: number;
  cacheRead: number;
}

const PRICES: Record<string, Price> = {
  // Anthropic Claude (per 1M tokens, USD)
  "claude-opus-4-8": { input: 15, output: 75, cacheCreation: 18.75, cacheRead: 1.5 },
  "claude-sonnet-4-5": { input: 3, output: 15, cacheCreation: 3.75, cacheRead: 0.3 },
  "claude-haiku-4-5": { input: 1, output: 5, cacheCreation: 1.25, cacheRead: 0.1 },
  // OpenAI Codex / GPT
  "gpt-5.6-sol": { input: 2, output: 8, cacheCreation: 0, cacheRead: 0.5 },
  "gpt-5": { input: 2, output: 8, cacheCreation: 0, cacheRead: 0.5 },
};

export function estimateCost(model: string | null | undefined, e: UsageEventInput): number {
  if (!model) return 0;
  const p = PRICES[model] ?? matchByPrefix(model);
  if (!p) return 0;
  const m = 1_000_000;
  return (
    (e.inputTokens * p.input +
      e.outputTokens * p.output +
      e.cacheCreationTokens * p.cacheCreation +
      e.cacheReadTokens * p.cacheRead) /
    m
  );
}

function matchByPrefix(model: string): Price | undefined {
  const m = model.toLowerCase();
  if (m.startsWith("claude-opus")) return PRICES["claude-opus-4-8"];
  if (m.startsWith("claude-sonnet")) return PRICES["claude-sonnet-4-5"];
  if (m.startsWith("claude-haiku")) return PRICES["claude-haiku-4-5"];
  if (m.startsWith("gpt-5")) return PRICES["gpt-5"];
  return undefined;
}
