import Foundation

/// 线上定价抓取。抽成协议以便测试注入。
protocol PricingFetcher {
    func fetch() async throws -> [String: Any]
}

/// 磁盘缓存。抽成协议以便测试注入。
protocol PricingCache {
    /// 返回缓存内容与其年龄；无缓存时返回 nil。
    func read() -> (json: [String: Any], age: TimeInterval)?
    func write(_ json: [String: Any])
}

/// LiteLLM 定价 JSON 的线上地址。对齐 ccusage `LITELLM_PRICING_URL`。
let liteLLMPricingURL = URL(string:
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

/// 硬编码定价覆盖表。对齐 ccusage `put_builtin_pricing()`（pricing.rs:667-1173）。
///
/// 存在的理由：这些模型可能尚未进入 LiteLLM，或 LiteLLM 的数据不准。
/// 实测本机有 855 条 `claude-opus-4-8` 记录。
func builtinPricingOverrides() -> [String: ModelPricing] {
    func anthropic(input: Double, output: Double, cacheCreate: Double, cacheRead: Double,
                   fast: Double = 1.0) -> ModelPricing {
        ModelPricing(input: input, output: output, cacheCreate: cacheCreate,
                     cacheRead: cacheRead, cacheReadExplicit: true,
                     inputAbove200k: nil, outputAbove200k: nil,
                     cacheCreateAbove200k: nil, cacheReadAbove200k: nil,
                     longContextThreshold: nil, fastMultiplier: fast)
    }
    return [
        "claude-opus-4-8": anthropic(input: 5e-6, output: 25e-6,
                                     cacheCreate: 6.25e-6, cacheRead: 0.5e-6, fast: 2.0),
        "claude-opus-4-7": anthropic(input: 5e-6, output: 25e-6,
                                     cacheCreate: 6.25e-6, cacheRead: 0.5e-6, fast: 6.0),
        "claude-opus-4-6": anthropic(input: 5e-6, output: 25e-6,
                                     cacheCreate: 6.25e-6, cacheRead: 0.5e-6, fast: 6.0),
    ]
}

/// 分层定价源：内置快照 → builtin 覆盖 → 磁盘缓存 → 线上抓取。
///
/// **非线程安全**——`refresh()` 与 `pricing(for:)` 需由调用方串行化
/// （P3 中由 `@MainActor` 保证）。
final class PricingStore: PricingSource {
    private var table: PricingTable
    private var snapshot: [String: Any]
    private let cache: PricingCache
    private let fetcher: PricingFetcher
    private let cacheTTL: TimeInterval

    init(builtinSnapshot: [String: Any],
         cache: PricingCache,
         fetcher: PricingFetcher,
         cacheTTL: TimeInterval = 24 * 3600) {
        self.snapshot = builtinSnapshot
        self.cache = cache
        self.fetcher = fetcher
        self.cacheTTL = cacheTTL
        self.table = PricingTable(entries: [:])
        rebuild(withFetched: nil)
    }

    func pricing(for model: String) -> ModelPricing? {
        table.pricing(for: model)
    }

    /// 抓取线上定价并覆盖。失败时静默保留现有定价——
    /// 网络问题绝不能影响速率显示。
    func refresh() async {
        guard let fetched = try? await fetcher.fetch(), !fetched.isEmpty else { return }
        cache.write(fetched)
        rebuild(withFetched: fetched)
    }

    // MARK: - private

    private func rebuild(withFetched fetched: [String: Any]?) {
        // 1. 内置快照
        var entries = decodeLiteLLMPricing(snapshot)
        // 2. builtin 硬编码表覆盖
        for (k, v) in builtinPricingOverrides() { entries[k] = v }
        // 3. 未过期的磁盘缓存覆盖
        if let (cached, age) = cache.read(), age <= cacheTTL {
            for (k, v) in decodeLiteLLMPricing(cached) { entries[k] = v }
        }
        // 4. 本次抓取结果覆盖
        if let fetched {
            for (k, v) in decodeLiteLLMPricing(fetched) { entries[k] = v }
        }
        table = PricingTable(entries: entries, aliases: ["gpt-5.3-spark": "gpt-5.3-codex-spark"])
    }
}

// MARK: - 生产实现

/// 走 URLSession 的抓取器，10 秒超时（对齐 ccusage `PRICING_FETCH_TIMEOUT_SECONDS`）。
struct URLSessionPricingFetcher: PricingFetcher {
    func fetch() async throws -> [String: Any] {
        var request = URLRequest(url: liteLLMPricingURL)
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// 写到 `~/Library/Application Support/VibeCompanion/pricing-cache.json`。
struct FilePricingCache: PricingCache {
    private var url: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VibeCompanion", isDirectory: true)
            .appendingPathComponent("pricing-cache.json")
    }

    func read() -> (json: [String: Any], age: TimeInterval)? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate
        else { return nil }
        return (json, Date().timeIntervalSince(modified))
    }

    func write(_ json: [String: Any]) {
        guard let url, let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// 从 app bundle 读取内置快照。
func loadBuiltinPricingSnapshot() -> [String: Any] {
    guard let url = Bundle.module.url(forResource: "litellm-pricing-snapshot",
                                      withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return json
}
