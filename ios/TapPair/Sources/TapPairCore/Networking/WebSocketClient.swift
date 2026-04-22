// Networking/WebSocketClient.swift
//
// Thin wrapper around `URLSessionWebSocketTask` that:
//   - encodes outgoing `ClientMessage`s as JSON
//   - decodes incoming text frames into `ServerMessage`s
//   - exposes received messages as an AsyncStream
//   - hides reconnection behind a simple state surface
//
// The protocol below (`WebSocketTransport`) lets unit tests substitute an
// in-memory transport so `GameStore` reducers can be exercised without any
// real socket.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol WebSocketTransport: AnyObject, Sendable {
    func connect(url: URL) async throws
    func send(text: String) async throws
    func receive() async throws -> String
    func close() async
}

public enum WebSocketClientError: Error {
    case notConnected
    case decode(String)
}

public actor WebSocketClient {
    private let transport: WebSocketTransport
    private var receiveTask: Task<Void, Never>?
    private let continuation: AsyncStream<ServerMessage>.Continuation
    public nonisolated let messages: AsyncStream<ServerMessage>

    public init(transport: WebSocketTransport) {
        self.transport = transport
        var cont: AsyncStream<ServerMessage>.Continuation!
        self.messages = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func connect(url: URL) async throws {
        try await transport.connect(url: url)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func send(_ message: ClientMessage) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        guard let s = String(data: data, encoding: .utf8) else {
            throw WebSocketClientError.decode("encode failed")
        }
        try await transport.send(text: s)
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        continuation.finish()
    }

    private func receiveLoop() async {
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            do {
                let text = try await transport.receive()
                guard let data = text.data(using: .utf8) else { continue }
                let msg = try decoder.decode(ServerMessage.self, from: data)
                continuation.yield(msg)
            } catch {
                continuation.finish()
                return
            }
        }
    }
}
