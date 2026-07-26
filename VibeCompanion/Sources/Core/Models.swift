import Foundation

// 旧的 UsageEvent 已被 Core/UsageEntry.swift 中的 UsageEntry 取代。
// 其 effectiveTokens 口径（input + output + cacheCreation）是本项目为压制
// 天文数字自创的，ccusage 无此概念；对应角色由 BurnRate 的
// tokensPerMinuteForIndicator（input + output）承担。
