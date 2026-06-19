//
//  ICMPPacket.swift
//  dart_ping_ios
//
//  ICMP Echo framing, checksum, and reply parsing for the native ping engine.
//
//  This file is deliberately Flutter-agnostic: it imports only Foundation/Darwin
//  and contains no plugin or channel code, so it can be unit-tested in isolation
//  (§spec:ios-tests) and reused independently of the Flutter boundary.
//

import Foundation

// MARK: - ICMP wire constants

/// ICMP message types we care about for IPv4 echo (RFC 792).
///
/// Note on the `SOCK_DGRAM`/`IPPROTO_ICMP` ("ping socket") path: on Darwin
/// (macOS/iOS) a datagram ICMP socket DOES deliver the leading IPv4 header on
/// receive (unlike Linux, which strips it). `PingEngine` strips that IPv4 header
/// before calling the parsers here, so these functions can index from offset 0
/// of their input as the ICMP header. The reply's TTL lives in that stripped
/// IPv4 header (and is also requestable out-of-band via a `recvmsg` control
/// message) — see `PingEngine`.
enum ICMPType {
    static let echoReply: UInt8 = 0    // Echo Reply (the response to our probe)
    static let echoRequest: UInt8 = 8  // Echo Request (what we send)
    static let timeExceeded: UInt8 = 11 // Time Exceeded (TTL hit zero in transit)
}

/// ICMPv6 message types we care about for IPv6 echo (RFC 4443).
///
/// Note on the `SOCK_DGRAM`/`IPPROTO_ICMPV6` ("ping6 socket") path: on Darwin
/// (macOS/iOS) a datagram ICMPv6 socket does NOT prepend an IPv6 header on
/// receive (unlike the IPv4 datagram-ICMP path, which delivers the leading IPv4
/// header). The datagram begins directly at the ICMPv6 message, so the v6
/// parsers below index from offset 0 with NO header to strip. The reply's hop
/// limit is therefore only available out-of-band, via an `IPV6_RECVHOPLIMIT`
/// `recvmsg` control message — see `PingEngine`.
///
/// The numeric values differ from IPv4 ICMP: echo request/reply are 128/129
/// (the high bit marks informational messages) and Time Exceeded is 3.
enum ICMPv6Type {
    static let timeExceeded: UInt8 = 3   // Time Exceeded (hop limit hit zero)
    static let echoRequest: UInt8 = 128  // Echo Request (what we send)
    static let echoReply: UInt8 = 129    // Echo Reply (the response to our probe)
}

/// Layout of an ICMP Echo header (8 bytes), big-endian on the wire:
///
///   byte 0:      type        (UInt8)
///   byte 1:      code        (UInt8)
///   bytes 2..3:  checksum    (UInt16, big-endian, one's-complement)
///   bytes 4..5:  identifier  (UInt16, big-endian)
///   bytes 6..7:  sequence    (UInt16, big-endian)
///   bytes 8..:   payload
///
/// We carry an 8-byte payload holding the send timestamp so RTT can be derived
/// from the echoed-back bytes if desired; the engine also keeps an authoritative
/// per-seq send-time table, so the payload is primarily a self-describing marker.
///
/// The ICMPv6 echo header (RFC 4443) shares this exact byte layout — only the
/// type discriminant differs — so the v6 framing/parsing below reuses these
/// offsets directly.
enum ICMPHeader {
    static let length = 8           // ICMP echo header is exactly 8 bytes
    static let typeOffset = 0
    static let codeOffset = 1
    static let checksumOffset = 2
    static let identifierOffset = 4
    static let sequenceOffset = 6
}

// MARK: - Packet construction

/// Builds and parses ICMP Echo packets.
///
/// All multi-byte header fields are serialized big-endian (network byte order),
/// matching the wire format and what peers expect.
public enum ICMPPacket {

    /// The fixed-size payload we attach to every Echo Request: an 8-byte
    /// big-endian send timestamp expressed in microseconds since the reference
    /// date. This makes the packet self-describing for debugging and lets a
    /// reply's echoed payload corroborate the engine's own send-time table.
    ///
    /// Internal: an implementation detail of `echoRequest`; not part of the
    /// test seam, so it stays out of the public API surface.
    static let payloadLength = 8

    /// Construct an ICMP Echo Request datagram.
    ///
    /// - Parameters:
    ///   - identifier: the echo identifier. On the Darwin `SOCK_DGRAM` ping
    ///     socket the kernel may OVERWRITE this with its own port-derived id and
    ///     recompute the checksum, so callers must not rely on it round-tripping.
    ///     We still set a sensible value and compute a correct checksum so the
    ///     packet is valid on a raw path too.
    ///   - sequence: the 16-bit sequence number used to match replies.
    ///   - sendTimeMicros: send timestamp (microseconds) embedded in the payload.
    /// - Returns: the complete ICMP message bytes (header + payload).
    public static func echoRequest(identifier: UInt16,
                                   sequence: UInt16,
                                   sendTimeMicros: UInt64) -> Data {
        var packet = Data(count: ICMPHeader.length + payloadLength)

        packet[ICMPHeader.typeOffset] = ICMPType.echoRequest
        packet[ICMPHeader.codeOffset] = 0
        // Checksum bytes (offset 2..3) start at zero; we fill them in last.
        writeUInt16BE(identifier, into: &packet, at: ICMPHeader.identifierOffset)
        writeUInt16BE(sequence, into: &packet, at: ICMPHeader.sequenceOffset)

        // Embed the send timestamp big-endian into the 8-byte payload.
        writeUInt64BE(sendTimeMicros, into: &packet, at: ICMPHeader.length)

        // Compute the one's-complement checksum over the ENTIRE ICMP message
        // (header with checksum field zeroed + payload), then store it big-endian.
        let sum = checksum(packet)
        writeUInt16BE(sum, into: &packet, at: ICMPHeader.checksumOffset)

        return packet
    }

    /// Construct an ICMPv6 Echo Request datagram (RFC 4443, type 128).
    ///
    /// The header layout is IDENTICAL to the IPv4 ICMP echo header — type, code,
    /// checksum, identifier, sequence at the same offsets — and we attach the
    /// same 8-byte big-endian send-timestamp payload, so the v6 parsers below
    /// (and the engine's per-seq matching) can share `ICMPHeader`'s offsets.
    ///
    /// CHECKSUM: unlike IPv4, the ICMPv6 checksum is computed over a pseudo-header
    /// that includes the IPv6 source and destination addresses, which we do NOT
    /// know here (the kernel selects the source address). On the Darwin
    /// `SOCK_DGRAM`/`IPPROTO_ICMPV6` path the kernel computes and fills in the
    /// ICMPv6 checksum for us, so we deliberately leave the checksum field zero
    /// rather than computing a (wrong, address-less) value here.
    ///
    /// - Parameters:
    ///   - identifier: the echo identifier. As with v4, the Darwin datagram
    ///     socket may overwrite this with its own port-derived id, so callers
    ///     must not rely on it round-tripping (we match by sequence only).
    ///   - sequence: the 16-bit sequence number used to match replies.
    ///   - sendTimeMicros: send timestamp (microseconds) embedded in the payload.
    /// - Returns: the complete ICMPv6 message bytes (header + payload), checksum 0.
    public static func echoRequestV6(identifier: UInt16,
                                     sequence: UInt16,
                                     sendTimeMicros: UInt64) -> Data {
        var packet = Data(count: ICMPHeader.length + payloadLength)

        packet[ICMPHeader.typeOffset] = ICMPv6Type.echoRequest
        packet[ICMPHeader.codeOffset] = 0
        // Checksum bytes (offset 2..3) are intentionally left zero: the kernel
        // computes the ICMPv6 checksum over the pseudo-header on the SOCK_DGRAM
        // path (see the method note above).
        writeUInt16BE(identifier, into: &packet, at: ICMPHeader.identifierOffset)
        writeUInt16BE(sequence, into: &packet, at: ICMPHeader.sequenceOffset)

        // Embed the send timestamp big-endian into the 8-byte payload, exactly
        // as the v4 echo does, so the on-wire payload layout is shared.
        writeUInt64BE(sendTimeMicros, into: &packet, at: ICMPHeader.length)

        return packet
    }

    // MARK: - Reply parsing

    /// A parsed ICMP Echo Reply.
    public struct EchoReply {
        public let identifier: UInt16
        public let sequence: UInt16
    }

    /// Attempt to interpret received bytes as an ICMP Echo Reply.
    ///
    /// On the `SOCK_DGRAM`/`IPPROTO_ICMP` path the bytes begin at the ICMP
    /// header (no leading IP header — see the note on `ICMPType`). We validate
    /// the type is Echo Reply (0) and extract the identifier and sequence so the
    /// engine can match the reply to a pending probe.
    ///
    /// - Returns: the parsed reply, or `nil` if the bytes are too short or are
    ///   not an Echo Reply (e.g. some other ICMP message the kernel delivered).
    public static func parseEchoReply(_ data: Data) -> EchoReply? {
        guard data.count >= ICMPHeader.length else { return nil }

        // Use a base-relative view so this works even if `data` is a slice with
        // a non-zero startIndex.
        let base = data.startIndex
        let type = data[base + ICMPHeader.typeOffset]
        guard type == ICMPType.echoReply else { return nil }

        let identifier = readUInt16BE(data, at: base + ICMPHeader.identifierOffset)
        let sequence = readUInt16BE(data, at: base + ICMPHeader.sequenceOffset)
        return EchoReply(identifier: identifier, sequence: sequence)
    }

    /// Attempt to interpret received bytes as an ICMP Time Exceeded message
    /// (type 11, e.g. TTL/hop-limit reached zero in transit) and extract the
    /// sequence number of the ORIGINAL Echo Request that triggered it.
    ///
    /// On the `SOCK_DGRAM`/`IPPROTO_ICMP` path the kernel strips the OUTER IPv4
    /// header (see the note on `ICMPType`), so a Time Exceeded message body is:
    ///
    ///   bytes 0..7:   the type-11 ICMP header (type=11, code, checksum, 4 unused)
    ///   byte 8..:     the ORIGINAL IPv4 header (the packet that expired). Its
    ///                 length is `(firstByte & 0x0F) * 4` bytes (IHL in 32-bit
    ///                 words; normally 20).
    ///   after that:   the ORIGINAL ICMP Echo header (8 bytes) — we read its
    ///                 sequence at `+ICMPHeader.sequenceOffset`.
    ///
    /// We match by SEQUENCE only and ignore the identifier, consistent with
    /// `parseEchoReply`: the kernel may have rewritten the identifier when our
    /// probe was sent on the datagram socket.
    ///
    /// - Returns: the original probe's sequence number, or `nil` if the bytes
    ///   are not a Time Exceeded message or are too short to contain the quoted
    ///   original Echo header.
    public static func parseTimeExceededOriginalSequence(_ data: Data) -> UInt16? {
        let base = data.startIndex

        // Need at least the 8-byte type-11 header before the quoted IP header.
        guard data.count >= ICMPHeader.length else { return nil }
        guard data[base + ICMPHeader.typeOffset] == ICMPType.timeExceeded else { return nil }

        // The original IPv4 header begins right after the type-11 header.
        let ipHeaderStart = base + ICMPHeader.length
        guard ipHeaderStart < data.endIndex else { return nil }

        // IHL (low nibble of the first IP byte) gives the IP header length in
        // 32-bit words; a valid IPv4 header is at least 20 bytes.
        let ihlWords = Int(data[ipHeaderStart] & 0x0F)
        let ipHeaderLength = ihlWords * 4
        guard ipHeaderLength >= 20 else { return nil }

        // The quoted original ICMP Echo header follows the original IP header.
        let echoStart = ipHeaderStart + ipHeaderLength

        // We need the full 8-byte original Echo header to reach the sequence field.
        guard echoStart + ICMPHeader.length <= data.endIndex else { return nil }

        return readUInt16BE(data, at: echoStart + ICMPHeader.sequenceOffset)
    }

    /// Attempt to interpret received bytes as an ICMPv6 Echo Reply (type 129).
    ///
    /// On the `SOCK_DGRAM`/`IPPROTO_ICMPV6` path the bytes begin at the ICMPv6
    /// header with NO leading IPv6 header (see the note on `ICMPv6Type`), so the
    /// header layout is identical to v4 — we reuse `ICMPHeader`'s offsets — and
    /// only the type discriminant differs (129 instead of 0).
    ///
    /// - Returns: the parsed reply, or `nil` if the bytes are too short or are
    ///   not an ICMPv6 Echo Reply.
    public static func parseEchoReplyV6(_ data: Data) -> EchoReply? {
        guard data.count >= ICMPHeader.length else { return nil }

        let base = data.startIndex
        let type = data[base + ICMPHeader.typeOffset]
        guard type == ICMPv6Type.echoReply else { return nil }

        let identifier = readUInt16BE(data, at: base + ICMPHeader.identifierOffset)
        let sequence = readUInt16BE(data, at: base + ICMPHeader.sequenceOffset)
        return EchoReply(identifier: identifier, sequence: sequence)
    }

    /// Attempt to interpret received bytes as an ICMPv6 Time Exceeded message
    /// (type 3, e.g. hop limit reached zero in transit) and extract the sequence
    /// number of the ORIGINAL Echo Request that triggered it.
    ///
    /// On the `SOCK_DGRAM`/`IPPROTO_ICMPV6` path there is NO outer IPv6 header on
    /// the received message, so the layout is:
    ///
    ///   bytes 0..7:    the type-3 ICMPv6 header (type=3, code, checksum, 4 unused)
    ///   bytes 8..47:   the quoted ORIGINAL IPv6 header. Unlike IPv4 there is no
    ///                  variable IHL: an IPv6 header is a FIXED 40 bytes. (We do
    ///                  not chase extension headers here; our own probe carries
    ///                  none, so the quoted original starts with the base header
    ///                  immediately followed by the original ICMPv6 echo.)
    ///   bytes 48..:    the quoted ORIGINAL ICMPv6 Echo header (8 bytes) — we read
    ///                  its sequence at `+ICMPHeader.sequenceOffset` (offset 48+6).
    ///
    /// We match by SEQUENCE only and ignore the identifier, consistent with
    /// `parseEchoReply`/`parseEchoReplyV6`.
    ///
    /// - Returns: the original probe's sequence number, or `nil` if the bytes are
    ///   not a Time Exceeded message or are too short to contain the quoted echo.
    public static func parseTimeExceededOriginalSequenceV6(_ data: Data) -> UInt16? {
        let base = data.startIndex

        // Need at least the 8-byte type-3 header before the quoted IPv6 header.
        guard data.count >= ICMPHeader.length else { return nil }
        guard data[base + ICMPHeader.typeOffset] == ICMPv6Type.timeExceeded else { return nil }

        // The quoted original IPv6 header is a fixed 40 bytes and begins right
        // after the 8-byte type-3 header; the original ICMPv6 echo follows it.
        let ipv6HeaderLength = 40
        let echoStart = base + ICMPHeader.length + ipv6HeaderLength

        // We need the full 8-byte original Echo header to reach the sequence field.
        guard echoStart + ICMPHeader.length <= data.endIndex else { return nil }

        return readUInt16BE(data, at: echoStart + ICMPHeader.sequenceOffset)
    }

    // MARK: - Receive framing (Darwin leading IPv4 header)

    /// A received datagram after its leading IPv4 header has been stripped: the
    /// ICMP message (starting at the ICMP header) plus the IP header's TTL.
    public struct ReceivedDatagram {
        /// The IPv4 header's TTL field (offset 8). For an Echo Reply this is the
        /// reply's remaining hop count, the value the other platforms report.
        public let ttl: Int
        /// The ICMP message bytes, starting at the ICMP header (offset 0), ready
        /// for `parseEchoReply` / `parseTimeExceededOriginalSequence`.
        public let icmpMessage: Data
    }

    /// Strip the leading IPv4 header that Darwin's `SOCK_DGRAM`/`IPPROTO_ICMP`
    /// socket delivers ahead of the ICMP message on receive (unlike Linux, which
    /// strips it for us — see the note on `ICMPType`).
    ///
    /// Returns the ICMP message and the IP header's TTL, or `nil` if the bytes
    /// are not a plausible IPv4 datagram (wrong version nibble, IHL below the
    /// 20-byte minimum) or are too short to hold the IPv4 header plus at least
    /// one ICMP header byte.
    ///
    /// IPv4 ONLY: the v6 datagram path delivers no leading IP header, so the
    /// engine does not call this for v6 (see `PingEngine`).
    public static func stripIPv4Header(_ data: Data) -> ReceivedDatagram? {
        let base = data.startIndex

        // Need at least a minimum (20-byte) IPv4 header to read version/IHL/TTL.
        guard data.count >= 20 else { return nil }

        // High nibble of byte 0 is the IP version; we only handle IPv4 here.
        let firstByte = data[base]
        guard (firstByte >> 4) == 4 else { return nil }

        // Low nibble is IHL in 32-bit words; a valid IPv4 header is >= 20 bytes.
        let ipHeaderLength = Int(firstByte & 0x0F) * 4
        guard ipHeaderLength >= 20, data.count > ipHeaderLength else { return nil }

        let ttl = Int(data[base + 8]) // IPv4 TTL field lives at offset 8.
        let icmpMessage = Data(data[(base + ipHeaderLength)..<data.endIndex])
        return ReceivedDatagram(ttl: ttl, icmpMessage: icmpMessage)
    }

    // MARK: - Checksum

    /// Standard Internet checksum (RFC 1071): the 16-bit one's-complement of the
    /// one's-complement sum of all 16-bit words in the buffer.
    ///
    /// Bytes are summed as big-endian 16-bit words; a trailing odd byte is
    /// padded with a zero low byte. Carries are folded back into the low 16 bits,
    /// and the final result is bit-inverted. The checksum field itself must be
    /// zero in `data` when this is computed.
    public static func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = data.startIndex
        let end = data.endIndex

        // Sum complete 16-bit big-endian words.
        while index + 1 < end {
            let high = UInt32(data[index]) << 8
            let low = UInt32(data[index + 1])
            sum &+= (high | low)
            index += 2
        }

        // Handle a trailing odd byte: treat it as the high byte of a word whose
        // low byte is zero.
        if index < end {
            sum &+= UInt32(data[index]) << 8
        }

        // Fold any carry bits from the high 16 into the low 16, repeatedly,
        // until nothing remains above bit 15.
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }

        // One's complement of the folded sum.
        return UInt16(truncatingIfNeeded: ~sum)
    }

    // MARK: - Byte helpers (big-endian)

    private static func writeUInt16BE(_ value: UInt16, into data: inout Data, at offset: Int) {
        let base = data.startIndex + offset
        data[base] = UInt8(truncatingIfNeeded: value >> 8)
        data[base + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func writeUInt64BE(_ value: UInt64, into data: inout Data, at offset: Int) {
        let base = data.startIndex + offset
        for i in 0..<8 {
            let shift = UInt64(8 * (7 - i))
            data[base + i] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let high = UInt16(data[offset]) << 8
        let low = UInt16(data[offset + 1])
        return high | low
    }
}
