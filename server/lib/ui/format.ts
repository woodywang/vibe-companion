// 格式化数字：1234 -> 1.2k / 1.23M
export function fmtTokens(n: number): string {
  if (n < 1000) return String(n);
  if (n < 1_000_000) return (n / 1000).toFixed(n < 10_000 ? 1 : 0) + "k";
  return (n / 1_000_000).toFixed(2) + "M";
}

export function fmtCost(n: number): string {
  if (n < 0.01) return "$" + n.toFixed(4);
  return "$" + n.toFixed(2);
}

export function fmtRate(tokensPerMin: number): string {
  return fmtTokens(tokensPerMin) + "/min";
}

export function fmtRelative(ms: number | null | undefined): string {
  if (!ms) return "从未";
  const diff = Date.now() - ms;
  if (diff < 60_000) return "刚刚";
  if (diff < 3_600_000) return Math.floor(diff / 60_000) + " 分钟前";
  if (diff < 86_400_000) return Math.floor(diff / 3_600_000) + " 小时前";
  return Math.floor(diff / 86_400_000) + " 天前";
}

export function fmtDate(date: string): string {
  // YYYY-MM-DD -> M/D
  const [, m, d] = date.split("-");
  return `${parseInt(m)}/${parseInt(d)}`;
}
