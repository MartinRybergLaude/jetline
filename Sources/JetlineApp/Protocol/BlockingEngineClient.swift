import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A blocking request/response client for the engine's unix socket, for the
/// command-line tools (`jetlined rpc`, `jetlined mcp`) that make a call and
/// wait for its reply. Greets with `toolHello`, so the engine sends it no
/// snapshot and no events.
final class BlockingEngineClient {
    private let fd: Int32
    private var nextId: UInt64 = 1
    private var inbox = Data()

    init(socketPath: String, clientName: String) throws {
        guard let fd = Sockets.connect(path: socketPath) else {
            throw WireError("Jetline isn't running.", code: "notRunning")
        }
        self.fd = fd
        _ = try call(API.ToolHello.method, [
            "protocolVersion": .int(Int64(Wire.protocolVersion)),
            "clientName": .string(clientName)
        ])
    }

    deinit { close(fd) }

    func call(_ method: String, _ params: JSONValue) throws -> JSONValue {
        let id = nextId
        nextId += 1
        let payload = JSONValue.object(["id": .int(Int64(id)), "method": .string(method), "params": params]).serialized()
        guard writeAll(fd: fd, FramedConnection.frame(.message, payload)) == nil else {
            throw WireError("Lost the connection to Jetline.")
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            while inbox.count >= 4 {
                let length = inbox.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard inbox.count >= 4 + length else { break }
                let kind = inbox[inbox.startIndex + 4]
                let body = inbox.subdata(in: (inbox.startIndex + 5)..<(inbox.startIndex + 4 + length))
                inbox.removeFirst(4 + length)
                guard kind == FrameKind.message.rawValue,
                      let message = try? JSONValue.parse(body),
                      message["type"]?.string == "response",
                      message["id"]?.int == Int(id) else { continue }
                if let error = message["error"], !error.isNull {
                    throw WireError(error["message"]?.string ?? "Jetline refused the call.")
                }
                return message["result"] ?? .null
            }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { throw WireError("Lost the connection to Jetline.") }
            inbox.append(contentsOf: buffer[0..<n])
        }
    }
}
