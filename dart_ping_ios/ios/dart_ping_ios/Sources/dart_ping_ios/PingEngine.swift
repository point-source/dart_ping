//
//  PingEngine.swift
//  dart_ping_ios
//
//  Self-contained, Flutter-agnostic native ICMP ping engine (§spec:swift-icmp-engine).
//
//  Design highlights:
//  - Unprivileged ICMP via socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) — and the
//    AF_INET6/IPPROTO_ICMPV6 equivalent for IPv6: the same mechanism Apple's
//    SimplePing uses, requiring NO entitlement, NO raw socket, and NO root
//    (§spec:no-special-entitlements).
//  - All cadence is driven by a DispatchSourceTimer; receiving runs on a
//    dedicated DispatchQueue; all mutable bookkeeping is serialized on a private
//    serial queue so counters and the per-seq send-time table are race-free.
//  - Family-faithful (§spec:address-family-error-honesty): the SELECTED address
//    family (IPv4 or IPv6) is resolved AND sent for — the engine NEVER silently
//    resolves or sends the other family. IPv4 uses ICMP over an
//    AF_INET/SOCK_DGRAM/IPPROTO_ICMP socket; IPv6 uses ICMPv6 over an
//    AF_INET6/SOCK_DGRAM/IPPROTO_ICMPV6 socket. Resolution and send failures are
//    classified HONESTLY: an address-family/route problem (e.g. an IPv4 literal
//    on an IPv6-only network) surfaces as `.noRoute`, distinct from a genuine
//    name-resolution miss (`.unknownHost`).
//  - The `ttl` field IS enforced: it sets the outgoing hop limit (IP_TTL for v4,
//    IPV6_UNICAST_HOPS for v6) and ICMP(v6) Time Exceeded replies from
//    intermediate hops are surfaced as `.timeToLiveExceeded` errors.
//
//  This file imports ONLY Foundation and Darwin — no Flutter.
//

import Foundation
import Darwin

/// Error kinds this engine can report: per-probe timeouts, TTL/hop-limit
/// exceeded by an intermediate hop, the run-level "no reply" (nothing came back
/// for the whole run), host-resolution failures, address-family/route failures
/// (resolution or send for the selected family is impossible on this network),
/// and the catch-all.
public enum PingErrorKind {
    case requestTimedOut
    case timeToLiveExceeded
    case noReply
    case unknownHost
    case noRoute
    case unknown
}

/// The IP address family this run resolves AND sends for. Authoritative: the
/// engine never falls back to the other family (§spec:address-family-error-honesty).
public enum IPFamily {
    case v4
    case v6
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
        public let ttl: Int               // outgoing hop limit (IP_TTL / IPV6_UNICAST_HOPS)
        public let family: IPFamily       // the selected family; resolved AND sent for

        public init(host: String,
                    count: Int?,
                    interval: TimeInterval,
                    timeout: TimeInterval,
                    ttl: Int,
                    family: IPFamily) {
            self.host = host
            self.count = count
            self.interval = interval
            self.timeout = timeout
            self.ttl = ttl
            self.family = family
        }
    }

    public enum Event {
        case response(seq: Int, ttl: Int, timeMs: Int, ip: String)
        case error(kind: PingErrorKind, seq: Int?, ip: String?)
        case summary(transmitted: Int, received: Int, timeMs: Int, errors: [PingErrorKind])
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
    /// The resolved target stored generically so it holds either a `sockaddr_in`
    /// (v4) or a `sockaddr_in6` (v6); `destinationLen` is the matching socklen
    /// passed to `sendto`.
    private var destination: sockaddr_storage?
    private var destinationLen: socklen_t = 0
    private let identifier: UInt16 = UInt16(truncatingIfNeeded: getpid())

    private var nextSequence: UInt16 = 0        // next seq to send
    private var sentCount = 0                    // total probes transmitted
    private var receivedCount = 0                // total replies matched
    private var totalRTTMillis = 0               // sum of matched RTTs (ms)

    /// Every error kind emitted during the run, in emission order, so the final
    /// summary can carry the full error list (parity with the other platforms,
    /// where `summary.errors` aggregates everything seen on the stream).
    private var accumulatedErrors: [PingErrorKind] = []

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

            // 1) Resolve the host for the SELECTED family. On failure: emit the
            //    HONEST kind (unknownHost vs noRoute, classified from the
            //    getaddrinfo status) + empty summary, then stop. We NEVER resolve
            //    the other family as a fallback (§spec:address-family-error-honesty).
            let resolution = self.resolve(host: self.config.host, family: self.config.family)
            switch resolution {
            case let .failure(kind):
                self.emit(.error(kind: kind, seq: nil, ip: nil))
                self.finishWithSummaryLocked()
                self.stopped = true
                return
            case let .success(addr, addrLen):
                self.destination = addr
                self.destinationLen = addrLen
            }

            // 2) Open the unprivileged ICMP/ICMPv6 datagram socket for the family.
            let fd: Int32
            switch self.config.family {
            case .v4:
                fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            case .v6:
                fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
            }
            guard fd >= 0 else {
                // socket() failure is an unexpected system error -> .unknown.
                self.emit(.error(kind: .unknown, seq: nil, ip: nil))
                self.finishWithSummaryLocked()
                self.stopped = true
                return
            }
            self.socketFD = fd

            // Request the reply's hop limit be delivered as a control message so
            // we can read it via recvmsg (it is NOT in the datagram payload on the
            // SOCK_DGRAM path). Best-effort: if this fails we simply report ttl 0.
            // v4 uses IP_RECVTTL (datum: a single u_char); v6 uses
            // IPV6_RECVHOPLIMIT (datum: an Int32) — see extractTTL.
            var on: Int32 = 1
            switch self.config.family {
            case .v4:
                setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))
            case .v6:
                setsockopt(fd, IPPROTO_IPV6, IPV6_RECVHOPLIMIT, &on, socklen_t(MemoryLayout<Int32>.size))
            }

            // Set the outgoing hop limit (TTL). Best-effort, like the RECV option:
            // when the limit is exceeded in transit an intermediate hop replies
            // with ICMP(v6) Time Exceeded, which we surface as .timeToLiveExceeded.
            // v4: IP_TTL; v6: IPV6_UNICAST_HOPS (both take an Int32).
            var ttlVal = Int32(self.config.ttl)
            switch self.config.family {
            case .v4:
                setsockopt(fd, IPPROTO_IP, IP_TTL, &ttlVal, socklen_t(MemoryLayout<Int32>.size))
            case .v6:
                setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &ttlVal, socklen_t(MemoryLayout<Int32>.size))
            }

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

            // Report each probe still awaiting a reply as timed out before we
            // drop it, so `transmitted`/`received` and the per-probe error
            // stream stay consistent with the other platforms instead of
            // silently losing sent-but-unanswered probes.
            let pendingSeqs = self.pendingSendTimes.keys.sorted()
            self.pendingSendTimes.removeAll()
            for seq in pendingSeqs {
                self.emit(.error(kind: .requestTimedOut, seq: Int(seq), ip: nil))
            }

            self.finishWithSummaryLocked()
        }
    }

    // MARK: - Host resolution

    /// Outcome of resolving the host for the selected family: either a copied
    /// destination sockaddr (in a `sockaddr_storage`) with its matching socklen,
    /// or the HONEST error kind that classifies the failure.
    private enum Resolution {
        case success(sockaddr_storage, socklen_t)
        case failure(PingErrorKind)
    }

    /// Resolve `host` to a destination for the SELECTED `family` using
    /// getaddrinfo, with `ai_family` pinned to AF_INET or AF_INET6 — NEVER the
    /// other family. The getaddrinfo status is captured and classified honestly:
    /// a genuine name miss becomes `.unknownHost`, an address-family/route
    /// problem becomes `.noRoute` (§spec:address-family-error-honesty).
    private func resolve(host: String, family: IPFamily) -> Resolution {
        var hints = addrinfo()
        hints.ai_family = (family == .v4) ? AF_INET : AF_INET6  // pinned; never the other family
        hints.ai_socktype = SOCK_DGRAM
        // NB: do NOT constrain ai_protocol to IPPROTO_ICMP(V6) here. getaddrinfo
        // validates the socktype/protocol pair and rejects SOCK_DGRAM+ICMP with
        // EAI_BADHINTS, which would make every host resolve as a failure. The
        // protocol only matters for the socket() call, not for name resolution.

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            if result != nil { freeaddrinfo(result) }
            return .failure(Self.errorKind(forGetaddrinfoStatus: status))
        }
        defer { freeaddrinfo(first) }

        // Walk the list for the first entry matching the requested family and
        // copy its sockaddr into a sockaddr_storage with the right socklen.
        let wantFamily: Int32 = (family == .v4) ? AF_INET : AF_INET6
        let wantLen = socklen_t((family == .v4) ? MemoryLayout<sockaddr_in>.size
                                                : MemoryLayout<sockaddr_in6>.size)
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if current.pointee.ai_family == wantFamily,
               let sa = current.pointee.ai_addr {
                var out = sockaddr_storage()
                let copyLen = min(Int(wantLen), Int(current.pointee.ai_addrlen))
                withUnsafeMutablePointer(to: &out) { dst in
                    dst.withMemoryRebound(to: UInt8.self, capacity: copyLen) { dstBytes in
                        memcpy(dstBytes, sa, copyLen)
                    }
                }
                return .success(out, wantLen)
            }
            node = current.pointee.ai_next
        }
        // getaddrinfo succeeded but returned no address of the selected family:
        // there is no route for this family, not a name miss.
        return .failure(.noRoute)
    }

    /// Classify a `getaddrinfo` status code into an honest error kind.
    ///
    /// Pure/static so it can be unit-tested without the network. Mapping
    /// (§spec:address-family-error-honesty):
    ///   - EAI_NONAME / EAI_NODATA / EAI_FAIL / EAI_AGAIN -> .unknownHost
    ///     (genuine name resolution: no such name, no data, permanent/temporary
    ///     resolver failure).
    ///   - EAI_ADDRFAMILY / EAI_FAMILY -> .noRoute (the requested address family
    ///     is unavailable for this host/network).
    ///   - any other non-zero status -> .unknownHost (conservative default for a
    ///     resolution failure).
    public static func errorKind(forGetaddrinfoStatus status: Int32) -> PingErrorKind {
        switch status {
        case EAI_NONAME, EAI_NODATA, EAI_FAIL, EAI_AGAIN:
            return .unknownHost
        case EAI_ADDRFAMILY, EAI_FAMILY:
            return .noRoute
        default:
            return .unknownHost
        }
    }

    /// Classify a `sendto` errno into an honest error kind.
    ///
    /// Pure/static so it can be unit-tested without a socket. Mapping
    /// (§spec:address-family-error-honesty):
    ///   - ENETUNREACH / EHOSTUNREACH / EAFNOSUPPORT / EADDRNOTAVAIL -> .noRoute
    ///     (network/host unreachable for this family, family not supported, or no
    ///     usable source address of this family).
    ///   - everything else -> .unknown.
    public static func errorKind(forSendErrno errno: Int32) -> PingErrorKind {
        switch errno {
        case ENETUNREACH, EHOSTUNREACH, EAFNOSUPPORT, EADDRNOTAVAIL:
            return .noRoute
        default:
            return .unknown
        }
    }

    // MARK: - Sending (all calls on stateQueue)

    private func scheduleSendTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
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
        let destLen = destinationLen

        let seq = nextSequence
        nextSequence = nextSequence &+ 1

        let nowMicros = Self.nowMicros()
        // Build the echo for the selected family (ICMP for v4, ICMPv6 for v6).
        let packet: Data
        switch config.family {
        case .v4:
            packet = ICMPPacket.echoRequest(identifier: identifier,
                                            sequence: seq,
                                            sendTimeMicros: nowMicros)
        case .v6:
            packet = ICMPPacket.echoRequestV6(identifier: identifier,
                                              sequence: seq,
                                              sendTimeMicros: nowMicros)
        }

        // Send to the resolved destination. sendto takes a generic sockaddr*;
        // we rebind the sockaddr_storage and pass the family-specific socklen.
        let sent: Int = packet.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &dest) { destPtr in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(socketFD,
                           raw.baseAddress,
                           packet.count,
                           0,
                           saPtr,
                           destLen)
                }
            }
        }

        guard sent >= 0 else {
            // Classify the send failure honestly: a family/route problem becomes
            // .noRoute (e.g. ENETUNREACH for an IPv4 literal on an IPv6-only
            // network), everything else stays .unknown.
            let kind = Self.errorKind(forSendErrno: errno)
            emit(.error(kind: kind, seq: Int(seq), ip: nil))
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
            self.emit(.error(kind: .requestTimedOut, seq: Int(seq), ip: nil))
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

    /// Blocking receive loop. Reads datagrams (with a hop-limit control message)
    /// until the socket is closed. Each well-formed Echo Reply is handed to the
    /// state queue for matching.
    private func receiveLoop(fd: Int32) {
        // The family is fixed for the whole run; capture it once.
        let family = config.family

        // Buffers reused across iterations.
        let bufferSize = 1500
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        // Control buffer big enough for a hop-limit cmsg with comfortable slack.
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

            let packet: Data
            let ttl: Int
            switch family {
            case .v4:
                // Darwin's SOCK_DGRAM/IPPROTO_ICMP socket delivers the FULL IPv4
                // header ahead of the ICMP message on receive (unlike Linux).
                // Strip it so the parsers see the ICMP header at offset 0, and
                // fall back to the stripped IP header's TTL if no cmsg is present.
                guard let datagram = ICMPPacket.stripIPv4Header(Data(buffer[0..<received])) else {
                    continue
                }
                packet = datagram.icmpMessage
                ttl = Self.extractHopLimit(from: &msg, family: family) ?? datagram.ttl
            case .v6:
                // The SOCK_DGRAM/IPPROTO_ICMPV6 socket does NOT prepend an IPv6
                // header: the datagram starts at the ICMPv6 message (offset 0).
                // There is no IP-header TTL fallback for v6, so an absent cmsg
                // reports hop limit 0.
                packet = Data(buffer[0..<received])
                ttl = Self.extractHopLimit(from: &msg, family: family) ?? 0
            }

            let sourceIP = Self.sourceIPString(from: &sourceAddr) ?? ""

            // Hand off to the state queue for sequence matching & emission.
            stateQueue.async { [weak self] in
                self?.handleReceivedLocked(packet: packet, ttl: ttl, sourceIP: sourceIP)
            }
        }

        // Loop ended (socket closed). Nothing further to do here; summary is
        // owned by completion/stop logic on the state queue.
    }

    /// Match a received ICMP(v6) message to a pending probe and emit a response.
    /// Runs on stateQueue.
    private func handleReceivedLocked(packet: Data, ttl: Int, sourceIP: String) {
        guard !summaryEmitted else { return }

        // ICMP(v6) Time Exceeded from an intermediate hop: the outgoing hop limit
        // reached zero before the destination. Match the QUOTED original probe by
        // sequence and report it as a TTL-exceeded error for that seq; this is
        // NOT a successful reply (no receivedCount / RTT contribution). The
        // message type and quoted-packet layout differ by family.
        let timeExceededType: UInt8 = (config.family == .v4) ? ICMPType.timeExceeded
                                                             : ICMPv6Type.timeExceeded
        if let first = packet.first, first == timeExceededType {
            let parsedSeq: UInt16?
            switch config.family {
            case .v4:
                parsedSeq = ICMPPacket.parseTimeExceededOriginalSequence(packet)
            case .v6:
                parsedSeq = ICMPPacket.parseTimeExceededOriginalSequenceV6(packet)
            }
            guard let seq = parsedSeq else { return }
            guard pendingSendTimes[seq] != nil else {
                // No pending probe for this seq (late/dup). Ignore, as with replies.
                return
            }
            // Resolve the probe's bookkeeping (cancel its timeout) but do NOT
            // treat it as received.
            pendingSendTimes.removeValue(forKey: seq)
            timeoutItems[seq]?.cancel()
            timeoutItems.removeValue(forKey: seq)

            emit(.error(kind: .timeToLiveExceeded, seq: Int(seq), ip: sourceIP))
            checkCompletionLocked()
            return
        }

        let reply: ICMPPacket.EchoReply?
        switch config.family {
        case .v4:
            reply = ICMPPacket.parseEchoReply(packet)
        case .v6:
            reply = ICMPPacket.parseEchoReplyV6(packet)
        }
        guard let echo = reply else { return }
        let seq = echo.sequence

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

        // Run-level "no reply": probes were sent but nothing came back. This
        // matches the Linux/macOS exit-code-1 semantics. Resolution/socket
        // failures have sentCount == 0, so they never acquire a spurious noReply.
        if receivedCount == 0 && sentCount > 0 {
            accumulatedErrors.append(.noReply)
        }

        emit(.summary(transmitted: sentCount,
                      received: receivedCount,
                      timeMs: totalRTTMillis,
                      errors: accumulatedErrors))

        // Closing the socket unblocks the receive loop (recvmsg returns < 0).
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    // MARK: - Emission

    /// Forward an event to the caller. Always invoked on stateQueue so ordering
    /// of emitted events matches the order state transitions occur.
    ///
    /// Every `.error` event is also recorded in `accumulatedErrors` (in emission
    /// order, before the summary is built) so the terminal summary can carry the
    /// full error list. Doing the bookkeeping here keeps every error call site
    /// from having to remember to append.
    private func emit(_ event: Event) {
        if case let .error(kind, _, _) = event {
            accumulatedErrors.append(kind)
        }
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

    /// Read the reply's hop limit (IPv4 TTL / IPv6 hop limit) from the recvmsg
    /// control messages, per family.
    ///
    /// For v4 we requested IP_RECVTTL, so the kernel attaches an ancillary
    /// message of level IPPROTO_IP / type IP_RECVTTL whose data is a single byte
    /// (u_char). For v6 we requested IPV6_RECVHOPLIMIT, so the kernel attaches a
    /// level IPPROTO_IPV6 / type IPV6_HOPLIMIT message whose data is an Int32. We
    /// walk the cmsg list with our Swift reimplementations of CMSG_FIRSTHDR /
    /// CMSG_NXTHDR (the C macros are not imported into Swift) and read the value
    /// at the correct width for the level. Returns nil if no matching cmsg is
    /// present (caller decides the fallback).
    private static func extractHopLimit(from msg: inout msghdr, family: IPFamily) -> Int? {
        var cmsg = cmsgFirstHeader(&msg)
        while let current = cmsg {
            switch family {
            case .v4:
                if current.pointee.cmsg_level == IPPROTO_IP,
                   current.pointee.cmsg_type == IP_RECVTTL {
                    // On Darwin/iOS the IP_RECVTTL ancillary datum is a single
                    // byte (u_char), so read exactly one byte. Reading a wider
                    // Int32 here would fold in adjacent cmsg padding/stale bytes
                    // (the control buffer is not re-zeroed per recvmsg) and yield
                    // a garbage TTL.
                    return Int(cmsgData(current).load(as: UInt8.self))
                }
            case .v6:
                if current.pointee.cmsg_level == IPPROTO_IPV6,
                   current.pointee.cmsg_type == IPV6_HOPLIMIT {
                    // The IPV6_HOPLIMIT ancillary datum is an Int32 (4 bytes),
                    // unlike the v4 single-byte u_char — read the full width.
                    return Int(cmsgData(current).load(as: Int32.self))
                }
            }
            cmsg = cmsgNextHeader(&msg, current)
        }
        return nil
    }

    // MARK: - CMSG macro reimplementations
    //
    // The POSIX CMSG_FIRSTHDR / CMSG_DATA / CMSG_NXTHDR helpers are C
    // function-like macros, which Swift's Clang importer does not surface, so we
    // reimplement them here following the Darwin <sys/socket.h> definitions.
    // Darwin aligns control-message components to 4 bytes (__DARWIN_ALIGN32).

    /// __DARWIN_ALIGN32: round `length` up to the next 4-byte boundary.
    private static func cmsgAlign(_ length: Int) -> Int {
        let alignment = MemoryLayout<UInt32>.size
        return (length + alignment - 1) & ~(alignment - 1)
    }

    /// CMSG_FIRSTHDR: first control header, or nil if the buffer is too small.
    private static func cmsgFirstHeader(_ msg: inout msghdr) -> UnsafeMutablePointer<cmsghdr>? {
        guard Int(msg.msg_controllen) >= MemoryLayout<cmsghdr>.size,
              let control = msg.msg_control else { return nil }
        return control.assumingMemoryBound(to: cmsghdr.self)
    }

    /// CMSG_DATA: pointer to the data following a control header.
    private static func cmsgData(_ cmsg: UnsafeMutablePointer<cmsghdr>) -> UnsafeRawPointer {
        return UnsafeRawPointer(cmsg).advanced(by: cmsgAlign(MemoryLayout<cmsghdr>.size))
    }

    /// CMSG_NXTHDR: next control header, or nil once the list is exhausted.
    private static func cmsgNextHeader(_ msg: inout msghdr,
                                       _ cmsg: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutablePointer<cmsghdr>? {
        guard let control = msg.msg_control else { return nil }
        let cmsgLen = Int(cmsg.pointee.cmsg_len)
        let base = UnsafeRawPointer(cmsg)
        let next = base.advanced(by: cmsgAlign(cmsgLen))
        // The next header must have room for at least a full cmsghdr.
        let nextEnd = next.advanced(by: cmsgAlign(MemoryLayout<cmsghdr>.size))
        let controlEnd = UnsafeRawPointer(control).advanced(by: Int(msg.msg_controllen))
        guard nextEnd <= controlEnd else { return nil }
        return UnsafeMutableRawPointer(mutating: next).assumingMemoryBound(to: cmsghdr.self)
    }

    /// Render the source sockaddr as a presentation string via inet_ntop,
    /// handling both AF_INET (dotted-quad) and AF_INET6 (colon-hex).
    private static func sourceIPString(from storage: inout sockaddr_storage) -> String? {
        switch Int32(storage.ss_family) {
        case AF_INET:
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let result: UnsafePointer<CChar>? = withUnsafePointer(to: &storage) { sp in
                sp.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sinPtr in
                    var addr = sinPtr.pointee.sin_addr
                    return inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
            }
            guard result != nil else { return nil }
            return String(cString: buffer)
        case AF_INET6:
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let result: UnsafePointer<CChar>? = withUnsafePointer(to: &storage) { sp in
                sp.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6Ptr in
                    var addr = sin6Ptr.pointee.sin6_addr
                    return inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                }
            }
            guard result != nil else { return nil }
            return String(cString: buffer)
        default:
            return nil
        }
    }
}
