import Foundation

/// 网络传输抽象：便于测试注入假实现。
protocol Transport {
    func send(_ req: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void)
}

extension URLSession: Transport {
    func send(_ req: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        dataTask(with: req, completionHandler: completion).resume()
    }
}

/// 上传器：定时或达阈值时把本地缓冲的用量事件批量上传到后端。
final class Uploader {
    private let store: UsageStore
    private var timer: Timer?
    private let transport: Transport
    private let now: () -> Date

    /// 认证失败（401/403）后置为 true，停止自动上传，直到重新配置 token。
    private(set) var authBlocked = false
    /// 瞬时失败的指数退避：在此时间之前不再自动重试。
    private(set) var nextRetryAt: Date?

    var onStatusChange: ((Status) -> Void)?

    enum Status: Equatable {
        case idle
        case uploading
        case success(count: Int)
        case failed(message: String)
    }

    init(store: UsageStore, transport: Transport? = nil, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        if let transport {
            self.transport = transport
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60
            self.transport = URLSession(configuration: cfg)
        }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: AppConfig.uploadIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.flush()
        }
        // 启动时立即试一次
        flush()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 重置认证阻断状态并恢复自动上传（例如保存新 token 后调用）。
    func resetAuthBlock() {
        authBlocked = false
        nextRetryAt = nil
        if timer == nil {
            start()
        }
    }

    /// 触发一次上传
    func flush() {
        guard Settings.shared.isRegistered, !Settings.shared.isPaused else { return }
        guard !authBlocked else { return }
        if let retryAt = nextRetryAt, now() < retryAt { return }

        let pending: [PendingEvent]
        do {
            pending = try store.fetchPending(limit: AppConfig.uploadBatchSize)
        } catch {
            onStatusChange?(.failed(message: "读取本地数据失败"))
            return
        }
        guard !pending.isEmpty else {
            onStatusChange?(.idle)
            return
        }

        onStatusChange?(.uploading)

        let events = pending.map { $0.toEvent() }
        let rowIds = pending.map { $0.rowid }
        let attempts = pending.map { $0.attempts }.max() ?? 0
        upload(events: events) { [weak self] result in
            guard let self else { return }
            do {
                switch result {
                case .success(let resp):
                    try self.store.markUploaded(rowIds: rowIds)
                    self.nextRetryAt = nil
                    self.onStatusChange?(.success(count: resp.inserted))
                case .failure(let err):
                    try? self.store.markFailed(rowIds: rowIds)
                    let nsErr = err as NSError
                    if nsErr.domain == "vc.auth" {
                        self.authBlocked = true
                        self.timer?.invalidate()
                        self.timer = nil
                        self.onStatusChange?(.failed(message: "认证失败，请重新注册"))
                    } else {
                        let backoff = min(pow(2, Double(attempts)) * 5, 300)
                        self.nextRetryAt = self.now().addingTimeInterval(backoff)
                        self.onStatusChange?(.failed(message: err.localizedDescription))
                    }
                }
            } catch {
                self.onStatusChange?(.failed(message: "更新本地状态失败"))
            }
        }
    }

    private func upload(events: [UsageEvent], completion: @escaping (Result<UsageBatchResponse, Error>) -> Void) {
        guard let token = Settings.shared.clientToken,
              let url = URL(string: "\(Settings.shared.apiBase)/api/usage/batch") else {
            completion(.failure(NSError(domain: "vc", code: 1, userInfo: [NSLocalizedDescriptionKey: "未注册"])))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = UsageBatchRequest(events: events)
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(error))
            return
        }

        transport.send(req) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                completion(.failure(NSError(domain: "vc.auth", code: code)))
                return
            }
            guard (200..<300).contains(code), let data = data,
                  let resp = try? JSONDecoder().decode(UsageBatchResponse.self, from: data) else {
                completion(.failure(NSError(domain: "vc", code: code, userInfo: [NSLocalizedDescriptionKey: "上传失败(\(code))"])))
                return
            }
            completion(.success(resp))
        }
    }
}
