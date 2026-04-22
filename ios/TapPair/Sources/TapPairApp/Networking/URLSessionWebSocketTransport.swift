// Networking/URLSessionWebSocketTransport.swift
//
// Concrete WebSocketTransport built on URLSessionWebSocketTask. Lives in the
// app target (not TapPairCore) because URLSessionWebSocketTask isn't fully
// available on Linux Foundation, and we want TapPairCore to stay portable.

#if canImport(Foundation)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TapPairCore

public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {

    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func connect(url: URL) async throws {
        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
    }

    public func send(text: String) async throws {
        guard let task else { throw WebSocketClientError.notConnected }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task else { throw WebSocketClientError.notConnected }
        let m = try await task.receive()
        switch m {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    public func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
#endif
