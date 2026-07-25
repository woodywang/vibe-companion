import Foundation

/// 上传器：定时或达阈值时把本地缓冲的用量事件批量上传到后端。
final class Uploader {
    private let store: UsageStore
    private var timer: Timer?
    private let session: URLSession

    var onStatusChange: ((Status) -> Void)?

    enum Status: Equatable {
        case idle
        case uploading
        case success(count: Int)
        case failed(message: String)
    }

    init(store: UsageStore) {
        self.store = store
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
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

    /// 触发一次上传
    func flush() {
        guard Settings.shared.isRegistered, !Settings.shared.isPaused else { return }

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
        upload(events: events) { [weak self] result in
            guard let self else { return }
            do {
                switch result {
                case .success(let resp):
                    try self.store.markUploaded(rowIds: rowIds)
                    self.onStatusChange?(.success(count: resp.inserted))
                case .failure(let err):
                    try? self.store.markFailed(rowIds: rowIds)
                    self.onStatusChange?(.failed(message: err.localizedDescription))
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

        let task = session.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let resp = try? JSONDecoder().decode(UsageBatchResponse.self, from: data) else {
                completion(.failure(NSError(domain: "vc", code: 2, userInfo: [NSLocalizedDescriptionKey: "解析响应失败"])))
                return
            }
            completion(.success(resp))
        }
        task.resume()
    }
}
