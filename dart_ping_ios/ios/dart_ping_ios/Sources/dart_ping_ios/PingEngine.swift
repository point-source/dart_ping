//
//  PingEngine.swift
//  dart_ping_ios
//
//  Self-contained, Flutter-agnostic native ICMP ping engine (§spec:swift-icmp-engine).
//
//  Design highlights:
//  - Unprivileged ICMP via socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP): the same
//    mechanism Apple's SimplePing uses, requiring NO entitlement, NO raw socket,
//    and NO root (§spec:no-special-entitlements).
//  - All cadence is driven by a DispatchSourceTimer; receiving runs on a
//    dedicated DispatchQueue; all mutable bookkeeping is serialized on a private
//    serial queue so counters and the per-seq send-time table are race-free.
//  - IPv4 only in this batch. The `ipv6` and `ttl` Config fields are accepted
//    but do not change behavior here (IPv6 and outgoing-TTL/Time-Exceeded are a
//    later batch).
//
//  This file imports ONLY Foundation and Darwin — no Flutter.
//

import Foundation
import Darwin

/// Error kinds this batch can report. TTL-exceeded / no-reply parity is a later
/// batch; here we surface only timeouts, resolution failures, and the catch-all.
public enum PingErrorKind {
    case requestTimedOut
    case unknownHost
    case unknown
}

/// A self-contained ICMP echo ping engine.
///
/// Usage: construct with a `Config` and an `onEvent` callback, call `start()`,
/// and (optionally) `stop()`. Events are delivered on a background queue; the
/// caller must tolerate that (the Flutter plugin hops back to the platform
/// thread itself).
public final class PingEngine {

    // MARK: - Public surface

    public struct Config {
        public let host: String
        public let count: Int?            // nil => run until stopped
        public let interval: TimeInterval // seconds between probes
        public let timeout: TimeInterval  // seconds to wait for a reply
        public let ttl: Int               // accepted but NOT enforced in this batch
        public let ipv6: Bool             // accepted; this batch resolves IPv4 only

        public init(host: String,
                    count: Int?,
                    interval: TimeInterval,
                    timeout: TimeInterval,
                    ttl: Int,
                    ipv6: Bool) {
            self.host = host
            self.count = count
            self.interval = interval
            self.timeout = timeout
            self.ttl = ttl
            self.ipv6 = ipv6
        }
    }

    public enum Event {
        case response(seq: Int, ttl: Int, timeMs: Int, ip: String)
        case error(kind: PingErrorKind, seq: Int?)
        case summary(transmitted: Int, received: Int, timeMs: Int)
    }

    public init(config: Config, onEvent: @escaping (Event) -> Void) {
        self.config = config
        self.onEvent = onEvent
    }

    // MARK: - Stored configuration & callback

    private let config: Config
    private let onEvent: (Event) -> Void

    // MARK: - Concurrency

    /// Serializes ALL mutable state below (counters, seq table, finished flag).
    /// Every read/write of that state happens on this queue so bookkeeping is
    /// race-free even though sends, receives, and timeouts run on other queues.
    private let stateQueue = DispatchQueue(label: "com.point-source.dart_ping_ios.engine.state")

    /// Dedicated queue that runs the blocking receive loop.
    private let receiveQueue = DispatchQueue(label: "com.point-source.dart_ping_ios.engine.receive")

    /// Timer that drives the send cadence (every `interval` seconds).
    private var sendTimer: DispatchSourceTimer?

    // MARK: - Mutable state (touch ONLY on stateQueue)

    private var socketFD: Int32 = -1
    private var destination: sockaddr_in?       // resolved IPv4 target
    private let identifier: UInt16 = UInt16(truncatingIfNeeded: getpid())

    private var nextSequence: UInt16 = 0        // next seq to send
    private var sentCount = 0                    // total probes transmitted
    private var receivedCount = 0                // total replies matched
    private var totalRTTMillis = 0               // sum of matched RTTs (ms)

    /// Per-seq send timestamps (microseconds) for probes still awaiting a reply
    /// or a timeout. Entries are removed when resolved (reply or timeout).
    private var pendingSendTimes: [UInt16: UInt64] = [:]

    /// Per-seq pending timeout work items, so a reply can cancel the timeout.
    private var timeoutItems: [UInt16: DispatchWorkItem] = [:]

    private var stopped = false                  // start()-then-stop() / count reached
    private var summaryEmitted = false           // ensures exactly one summary
    private var receiveLoopRunning = false

    // MARK: - Lifecycle

    /// Begin pinging. Resolves the host, opens the socket, starts the receive
    /// loop, and schedules the first probe immediately followed by `interval`
    /// spacing. Safe to call once; subsequent calls are ignored.
    public func start() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.stopped, self.socketFD == -1 else { return }

            // 1) Resolve the host (IPv4). On failure: unknownHost + empty summary, stop.
            guard let addr = self.resolveIPv4(host: self.config.host) else {
                self.emit(.error(kind: .unknownHost, seq: nil))
                self.finishWithSummaryLocked()
                self.stopped = true
                return
            }
            self.destination = addr

            // 2) Open the unprivileged ICMP datagram socket.
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            guard fd >= 0 else {
                // socket() failure is an unexpected system error -> .unknown.
                self.emit(.error(kind: .unknown, seq: nil))
                self.finishWithSummaryLocked()
                self.stopped = true
                return
            }
            self.socketFD = fd

            // Request the reply's IP TTL be delivered as a control message so we
            // can read it via recvmsg (it is NOT in the datagram payload on the
            // SOCK_DGRAM path). Best-effort: if this fails we simply report ttl 0.
            var on: Int32 = 1
            setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))

            // 3) Start receiving and schedule sends.
            self.startReceiveLoopLocked()
            self.scheduleSendTimerLocked()
        }
    }

    /// Halt further sends immediately, but still emit the final summary for what
    /// completed (matches the Ping stop() contract). Idempotent.
    public func stop() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.stopped else { return }
            self.stopped = true

            // Cancel cadence and any outstanding timeout work; we will not wait
            // for in-flight replies after an explicit stop.
            self.sendTimer?.cancel()
            self.sendTimer = nil
            for (_, item) in self.timeoutItems { item.cancel() }
            self.timeoutItems.removeAll()
            self.pendingSendTimes.removeAll()

            self.finishWithSummaryLocked()
        }
    }

    // MARK: - Host resolution

    /// Resolve `host` to an IPv4 `sockaddr_in` using getaddrinfo(AF_INET).
    /// Returns nil on any resolution failure.
    private func resolveIPv4(host: String) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET          // IPv4 only this batch
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_ICMP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            if result != nil { freeaddrinfo(result) }
            return nil
        }
        defer { freeaddrinfo(first) }

        // Walk the list for the first AF_INET entry and copy its sockaddr_in.
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if current.pointee.ai_family == AF_INET,
               let sa = current.pointee.ai_addr {
                var out = sockaddr_in()
                memcpy(&out, sa, MemoryLayout<sockaddr_in>.size)
                return out
            }
            node = current.pointee.ai_next
        }
        return nil
    }

    // MARK: - Sending (all calls on stateQueue)

    private func scheduleSendTimerLocked() {
        let timer = DispatchSourceTimer(queue: stateQueue)
        // Fire immediately, then every `interval` seconds.
        timer.schedule(deadline: .now(), repeating: config.interval)
        timer.setEventHandler { [weak self] in
            self?.sendNextProbeLocked()
        }
        sendTimer = timer
        timer.resume()
    }

    private func sendNextProbeLocked() {
        guard !stopped else { return }

        // Stop scheduling once we've sent `count` probes (count == nil => forever).
        if let count = config.count, sentCount >= count {
            sendTimer?.cancel()
            sendTimer = nil
            return
        }

        guard socketFD >= 0, var dest = destination else { return }

        let seq = nextSequence
        nextSequence = nextSequence &+ 1

        let nowMicros = Self.nowMicros()
        let packet = ICMPPacket.echoRequest(identifier: identifier,
                                            sequence: seq,
                                            sendTimeMicros: nowMicros)

        // Send to the resolved destination. sendto takes a generic sockaddr*.
        let sent: Int = packet.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &dest) { destPtr in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(socketFD,
                           raw.baseAddress,
                           packet.count,
                           0,
                           saPtr,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard sent >= 0 else {
            // A send failure is an unexpected system error for this seq.
            emit(.error(kind: .unknown, seq: Int(seq)))
            // Still count cadence so a transient failure doesn't stall completion
            // when a fixed count was requested.
            sentCount += 1
            checkCompletionLocked()
            return
        }

        // Record bookkeeping and arm a per-seq timeout.
        pendingSendTimes[seq] = nowMicros
        sentCount += 1
        armTimeoutLocked(for: seq)
    }

    /// Arm a timeout for `seq`; if no reply has resolved it within `timeout`
    /// seconds, mark it lost (requestTimedOut) and check for completion.
    private func armTimeoutLocked(for seq: UInt16) {
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Runs on stateQueue (we dispatch it there), so state is safe.
            guard self.pendingSendTimes[seq] != nil else { return } // already resolved
            self.pendingSendTimes.removeValue(forKey: seq)
            self.timeoutItems.removeValue(forKey: seq)
            self.emit(.error(kind: .requestTimedOut, seq: Int(seq)))
            self.checkCompletionLocked()
        }
        timeoutItems[seq] = item
        stateQueue.asyncAfter(deadline: .now() + config.timeout, execute: item)
    }

    // MARK: - Receiving

    private func startReceiveLoopLocked() {
        guard !receiveLoopRunning else { return }
        receiveLoopRunning = true
        let fd = socketFD
        receiveQueue.async { [weak self] in
            self?.receiveLoop(fd: fd)
        }
    }

    /// Blocking receive loop. Reads datagrams (with a TTL control message) until
    /// the socket is closed. Each well-formed Echo Reply is handed to the state
    /// queue for matching.
    private func receiveLoop(fd: Int32) {
        // Buffers reused across iterations.
        let bufferSize = 1500
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        // Control buffer big enough for an IP_TTL cmsg with comfortable slack.
        var control = [UInt8](repeating: 0, count: 256)
        var sourceAddr = sockaddr_storage()

        while true {
            var iov = iovec()
            var msg = msghdr()

            let received: Int = buffer.withUnsafeMutableBytes { bufRaw in
                control.withUnsafeMutableBytes { ctrlRaw in
                    withUnsafeMutablePointer(to: &sourceAddr) { addrPtr in
                        iov.iov_base = bufRaw.baseAddress
                        iov.iov_len = bufRaw.count

                        return withUnsafeMutablePointer(to: &iov) { iovPtr in
                            msg.msg_name = UnsafeMutableRawPointer(addrPtr)
                            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                            msg.msg_iov = iovPtr
                            msg.msg_iovlen = 1
                            msg.msg_control = ctrlRaw.baseAddress
                            msg.msg_controllen = socklen_t(ctrlRaw.count)
                            msg.msg_flags = 0
                            return recvmsg(fd, &msg, 0)
                        }
                    }
                }
            }

            if received < 0 {
                // EINTR: retry. Anything else (e.g. EBADF after close()) ends the loop.
                if errno == EINTR { continue }
                break
            }
            if received == 0 { continue }

            let packet = Data(buffer[0..<received])
            let ttl = Self.extractTTL(from: &msg) ?? 0
            let sourceIP = Self.sourceIPString(from: &sourceAddr) ?? ""

            // Hand off to the state queue for sequence matching & emission.
            stateQueue.async { [weak self] in
                self?.handleReceivedLocked(packet: packet, ttl: ttl, sourceIP: sourceIP)
            }
        }

        // Loop ended (socket closed). Nothing further to do here; summary is
        // owned by completion/stop logic on the state queue.
    }

    /// Match a received ICMP message to a pending probe and emit a response.
    /// Runs on stateQueue.
    private func handleReceivedLocked(packet: Data, ttl: Int, sourceIP: String) {
        guard !summaryEmitted else { return }

        guard let reply = ICMPPacket.parseEchoReply(packet) else { return }
        let seq = reply.sequence

        // Match strictly by sequence. (Identifier is intentionally NOT checked:
        // the kernel may rewrite it on the SOCK_DGRAM path, so the sequence
        // number is the reliable correlator.)
        guard let sendMicros = pendingSendTimes[seq] else {
            // No pending probe for this seq: a duplicate, a late reply past its
            // timeout, or an echo for a stale run. Ignore.
            return
        }

        // Resolve the probe: drop its pending state and cancel its timeout.
        pendingSendTimes.removeValue(forKey: seq)
        timeoutItems[seq]?.cancel()
        timeoutItems.removeValue(forKey: seq)

        let nowMicros = Self.nowMicros()
        let rttMicros = nowMicros >= sendMicros ? (nowMicros - sendMicros) : 0
        let rttMillis = Int((rttMicros + 500) / 1000) // round to nearest ms

        receivedCount += 1
        totalRTTMillis += rttMillis

        emit(.response(seq: Int(seq), ttl: ttl, timeMs: rttMillis, ip: sourceIP))
        checkCompletionLocked()
    }

    // MARK: - Completion / summary

    /// Determine whether the run has finished naturally: a finite `count` was
    /// requested, all of them were sent, and none remain pending. Emits the
    /// summary exactly once.
    private func checkCompletionLocked() {
        guard let count = config.count else { return } // count == nil => never auto-finishes
        guard !summaryEmitted else { return }
        guard sentCount >= count, pendingSendTimes.isEmpty else { return }

        // All probes accounted for (each got a reply or a timeout).
        sendTimer?.cancel()
        sendTimer = nil
        stopped = true
        finishWithSummaryLocked()
    }

    /// Emit the single summary event and tear down the socket. Idempotent via
    /// `summaryEmitted`.
    private func finishWithSummaryLocked() {
        guard !summaryEmitted else { return }
        summaryEmitted = true

        emit(.summary(transmitted: sentCount,
                      received: receivedCount,
                      timeMs: totalRTTMillis))

        // Closing the socket unblocks the receive loop (recvmsg returns < 0).
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    // MARK: - Emission

    /// Forward an event to the caller. Always invoked on stateQueue so ordering
    /// of emitted events matches the order state transitions occur.
    private func emit(_ event: Event) {
        onEvent(event)
    }

    // MARK: - Low-level helpers

    /// Monotonic-ish microsecond timestamp. We use gettimeofday for portability;
    /// RTT is a difference of two such samples taken close together, so the wall
    /// clock is adequate here (and matches the prior implementation's accuracy
    /// expectations — §spec accuracy tradeoff).
    private static func nowMicros() -> UInt64 {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return UInt64(tv.tv_sec) &* 1_000_000 &+ UInt64(tv.tv_usec)
    }

    /// Read the reply's IP TTL from the recvmsg control messages.
    ///
    /// We requested IP_RECVTTL, so the kernel attaches an ancillary message of
    /// level IPPROTO_IP / type IP_RECVTTL whose data is the IP header TTL. We
    /// walk the cmsg list with CMSG_FIRSTHDR/CMSG_NXTHDR and read the value.
    /// Returns nil if no TTL cmsg is present (caller reports 0).
    private static func extractTTL(from msg: inout msghdr) -> Int? {
        var cmsg = CMSG_FIRSTHDR(&msg)
        while let current = cmsg {
            if current.pointee.cmsg_level == IPPROTO_IP,
               current.pointee.cmsg_type == IP_RECVTTL {
                if let dataPtr = CMSG_DATA(current) {
                    // The TTL is delivered as an int (commonly a single byte's
                    // worth of value, but carried in an int-sized slot).
                    let value = dataPtr.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
                    return Int(value)
                }
            }
            cmsg = CMSG_NXTHDR(&msg, current)
        }
        return nil
    }

    /// Render the source sockaddr (IPv4) as a dotted-quad string via inet_ntop.
    private static func sourceIPString(from storage: inout sockaddr_storage) -> String? {
        guard Int32(storage.ss_family) == AF_INET else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result: UnsafePointer<CChar>? = withUnsafePointer(to: &storage) { sp in
            sp.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sinPtr in
                var addr = sinPtr.pointee.sin_addr
                return inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            }
        }
        guard result != nil else { return nil }
        return String(cString: buffer)
    }
}
