import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A TCP port something on the engine's machine is listening on.
struct ListeningPort: Codable, Sendable, Hashable, Identifiable {
    var port: Int
    /// What it's bound to: "127.0.0.1", "::1", "0.0.0.0", "::", or a
    /// specific interface address.
    var addresses: [String]
    /// The listening process's name, when it's readable ("node").
    var process: String?
    /// Worth forwarding without being asked: the user's own process on a
    /// port someone chose — not a system service, and not an ephemeral
    /// port a tool grabbed for itself (language servers, debug adapters).
    var suggested: Bool

    var id: Int { port }
}

/// Watches the machine's listening TCP ports: `/proc/net/tcp{,6}` on
/// Linux, `lsof` on macOS. Polls every couple of seconds while started and
/// reports the whole list whenever it changes.
final class PortScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jetline.ports", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    /// Nil until the first scan.
    private var latest: [ListeningPort]?
    /// Socket inode → process name (Linux), kept across scans.
    private var processNames: [UInt64: String] = [:]
    private let interval: DispatchTimeInterval

    /// Called on a background queue with the new list.
    var onChange: (@Sendable ([ListeningPort]) -> Void)?

    /// Reading /proc is cheap; `lsof` (macOS) is a subprocess, so it runs
    /// less often.
    #if os(Linux)
    static let defaultInterval: DispatchTimeInterval = .seconds(2)
    #else
    static let defaultInterval: DispatchTimeInterval = .seconds(5)
    #endif

    init(interval: DispatchTimeInterval = PortScanner.defaultInterval) {
        self.interval = interval
    }

    var current: [ListeningPort] { lock.withLock { latest ?? [] } }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Scan now and return the result (also reported through `onChange`).
    func scanNow() -> [ListeningPort] {
        queue.sync { tick() }
        return current
    }

    private func tick() {
        let ports = scan()
        let changed: Bool = lock.withLock {
            defer { latest = ports }
            return latest != ports
        }
        if changed { onChange?(ports) }
    }

    /// Addresses to try, in order, to reach `port` on this machine.
    func connectTargets(for port: Int) -> [String] {
        var targets: [String] = []
        for address in current.first(where: { $0.port == port })?.addresses ?? [] {
            switch address {
            case "0.0.0.0": targets.append("127.0.0.1")
            case "::": targets += ["::1", "127.0.0.1"]
            default: targets.append(address)
            }
        }
        targets += ["127.0.0.1", "::1"]
        var seen = Set<String>()
        return targets.filter { seen.insert($0).inserted }
    }

    // MARK: - Scanning

    private func scan() -> [ListeningPort] {
        #if os(Linux)
        return scanProc()
        #else
        return scanLsof()
        #endif
    }

    private struct Listener {
        var port: Int
        var address: String
        var ownedByUser: Bool
        var inode: UInt64
        var process: String?
    }

    private func merge(_ listeners: [Listener], ephemeral: ClosedRange<Int>) -> [ListeningPort] {
        var byPort: [Int: ListeningPort] = [:]
        var owned: [Int: Bool] = [:]
        for listener in listeners {
            var entry = byPort[listener.port] ?? ListeningPort(port: listener.port, addresses: [], process: nil, suggested: false)
            if !entry.addresses.contains(listener.address) { entry.addresses.append(listener.address) }
            entry.process = entry.process ?? listener.process
            owned[listener.port] = (owned[listener.port] ?? false) || listener.ownedByUser
            byPort[listener.port] = entry
        }
        return byPort.values.map { entry in
            var entry = entry
            entry.addresses.sort()
            entry.suggested = owned[entry.port] == true && entry.port >= 1024 && !ephemeral.contains(entry.port)
            return entry
        }
        .sorted { $0.port < $1.port }
    }

    #if os(Linux)
    private func scanProc() -> [ListeningPort] {
        let uid = UInt32(getuid())
        var listeners: [Listener] = []
        for (file, v6) in [("/proc/net/tcp", false), ("/proc/net/tcp6", true)] {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                // sl local rem st queues tr retrnsmt uid timeout inode
                guard fields.count >= 10, fields[3] == "0A" else { continue }
                let local = fields[1].split(separator: ":")
                guard local.count == 2, let port = Int(local[1], radix: 16),
                      let address = Self.procAddress(String(local[0]), v6: v6) else { continue }
                listeners.append(Listener(
                    port: port,
                    address: address,
                    ownedByUser: UInt32(fields[7]) == uid,
                    inode: UInt64(fields[9]) ?? 0
                ))
            }
        }
        let live = Set(listeners.map(\.inode))
        let unknown = live.subtracting(processNames.keys).subtracting([0])
        if !unknown.isEmpty { resolveProcesses(unknown) }
        processNames = processNames.filter { live.contains($0.key) }
        // "" marks an unreadable owner, looked up once; it reaches no one.
        for i in listeners.indices { listeners[i].process = processNames[listeners[i].inode].flatMap { $0.isEmpty ? nil : $0 } }
        return merge(listeners, ephemeral: Self.ephemeralRange())
    }

    /// Map socket inodes to process names by walking our own processes'
    /// fds (others' aren't readable). Only runs when a new listener shows up.
    private func resolveProcesses(_ inodes: Set<UInt64>) {
        let fm = FileManager.default
        guard let pids = try? fm.contentsOfDirectory(atPath: "/proc") else { return }
        var remaining = inodes
        for pid in pids where pid.first?.isNumber == true {
            guard let fds = try? fm.contentsOfDirectory(atPath: "/proc/\(pid)/fd") else { continue }
            for fd in fds {
                guard let link = try? fm.destinationOfSymbolicLink(atPath: "/proc/\(pid)/fd/\(fd)"),
                      link.hasPrefix("socket:["), let inode = UInt64(link.dropFirst(8).dropLast()),
                      remaining.contains(inode) else { continue }
                let name = (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                processNames[inode] = name ?? ""
                remaining.remove(inode)
            }
            if remaining.isEmpty { break }
        }
        // Unreadable (another user's): don't look again.
        for inode in remaining { processNames[inode] = "" }
    }

    /// `/proc/net/tcp` prints addresses as host-order 32-bit words in hex.
    static func procAddress(_ hex: String, v6: Bool) -> String? {
        let chars = Array(hex)
        guard chars.count == (v6 ? 32 : 8) else { return nil }
        var bytes: [UInt8] = []
        for word in stride(from: 0, to: chars.count, by: 8) {
            var wordBytes: [UInt8] = []
            for i in stride(from: word, to: word + 8, by: 2) {
                guard let b = UInt8(String(chars[i..<i + 2]), radix: 16) else { return nil }
                wordBytes.append(b)
            }
            bytes += wordBytes.reversed()
        }
        if !v6 { return bytes.map(String.init).joined(separator: ".") }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return bytes[12...].map(String.init).joined(separator: ".")
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(AF_INET6, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        return ok ? String(cString: buffer) : nil
    }

    private static func ephemeralRange() -> ClosedRange<Int> {
        if let text = try? String(contentsOfFile: "/proc/sys/net/ipv4/ip_local_port_range", encoding: .utf8) {
            let parts = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if parts.count == 2, parts[0] <= parts[1] { return parts[0]...parts[1] }
        }
        return 32768...60999
    }
    #else
    private func scanLsof() -> [ListeningPort] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-u", String(getuid()), "-Fctn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var listeners: [Listener] = []
        var command: String?
        var type = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": command = nil
            case "c": command = value
            case "t": type = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                var host = String(value[..<colon])
                if host == "*" { host = type == "IPv6" ? "::" : "0.0.0.0" }
                host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                listeners.append(Listener(port: port, address: host, ownedByUser: true, inode: 0, process: command))
            default: continue
            }
        }
        return merge(listeners, ephemeral: 49152...65535)
    }
    #endif
}
