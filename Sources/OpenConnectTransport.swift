import Foundation
import Network

struct APIReply: Decodable {
    let Code: Int
    let Message: String?
}

enum ConnectionError: LocalizedError {
    case network(String, Bool)
    case timeout(Bool)
    case closed(Bool)
    case badReply
    case rejected(Int, String)
    var errorDescription: String? {
        switch self {
        case .network(let message, let sent):
            return sent ? "전송 중 연결이 끊겼습니다. 재전송 전에 게임에서 샷 결과를 확인하세요. \(message)"
                : "연결할 수 없습니다. 게임과 주소·포트를 확인해 주세요. \(message)"
        case .timeout(let sent), .closed(let sent):
            return sent ? "전송 후 응답을 확인하지 못했습니다. 다시 보내기 전에 게임에서 샷 결과를 확인하세요."
                : "서버 응답이 없습니다. MuniGolf에서 연습장이나 코스를 열고 다시 연결해 주세요."
        case .badReply: return "Open Connect 서버 응답을 해석할 수 없습니다."
        case .rejected(let code, let message): return "서버가 전송을 거부했습니다 (\(code)): \(message)"
        }
    }
}

// TCP can split or join JSON objects, and the protocol does not require newlines.
struct JSONReplyFramer {
    private var pending = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        guard pending.count <= 262144 else { throw ConnectionError.badReply }
        let bytes = [UInt8](pending)
        var start: Int?
        var depth = 0
        var quoted = false
        var escaped = false
        var consumed = 0
        var frames: [Data] = []
        for (index, byte) in bytes.enumerated() {
            if start == nil {
                if [9, 10, 13, 32].contains(byte) { consumed = index + 1; continue }
                guard byte == 123 else { throw ConnectionError.badReply }
                start = index
                depth = 1
                continue
            }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0, let beginning = start {
                    frames.append(Data(bytes[beginning...index]))
                    consumed = index + 1
                    start = nil
                }
            }
        }
        if consumed > 0 { pending.removeFirst(consumed) }
        return frames
    }
}

enum OpenConnectTransport {
    static func exchange(host: String, port: UInt16, data: Data, timeout: TimeInterval = 7) async throws -> APIReply {
        try await withCheckedThrowingContinuation { continuation in
            ReplySession(host: host, port: port, data: data, timeout: timeout,
                         continuation: continuation).start()
        }
    }
}

// All callbacks and completion state are confined to one private serial queue.
private final class ReplySession {
    private let queue = DispatchQueue(label: "com.slee.sc4munisender.exchange")
    private let connection: NWConnection
    private let payload: Data
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<APIReply, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var sent = false
    private var started = false
    private var framer = JSONReplyFramer()

    init(host: String, port: UInt16, data: Data, timeout: TimeInterval,
         continuation: CheckedContinuation<APIReply, Error>) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        payload = data
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            guard continuation != nil else { return }
            switch state {
            case .ready:
                guard !started else { return }
                started = true
                // Once handed to TCP, a missing acknowledgement has an uncertain outcome.
                sent = true
                connection.send(content: payload, completion: .contentProcessed { [self] error in
                    guard continuation != nil else { return }
                    if let error = error { finish(.failure(ConnectionError.network(error.localizedDescription, sent))) }
                    else { receive() }
                })
            case .failed(let error): finish(.failure(ConnectionError.network(error.localizedDescription, sent)))
            case .cancelled: finish(.failure(ConnectionError.closed(sent)))
            default: break
            }
        }
        let work = DispatchWorkItem { [self] in finish(.failure(ConnectionError.timeout(sent))) }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, closed, error in
            guard continuation != nil else { return }
            do {
                for frame in try framer.append(data ?? Data()) {
                    let reply = try JSONDecoder().decode(APIReply.self, from: frame)
                    if reply.Code == 200 { finish(.success(reply)); return }
                    if reply.Code >= 400 {
                        finish(.failure(ConnectionError.rejected(reply.Code, reply.Message ?? ""))); return
                    }
                    // 201 is player/club information; wait for this request's acknowledgement.
                }
            } catch { finish(.failure(ConnectionError.badReply)); return }
            if let error = error { finish(.failure(ConnectionError.network(error.localizedDescription, sent))) }
            else if closed { finish(.failure(ConnectionError.closed(sent))) }
            else { receive() }
        }
    }

    private func finish(_ result: Result<APIReply, Error>) {
        guard let completion = continuation else { return }
        continuation = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion.resume(with: result)
    }
}
