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
/// Note on the `SOCK_DGRAM`/`IPPROTO_ICMP` ("ping socket") path: unlike a raw
/// socket, a datagram ICMP socket does NOT prepend the IPv4 header on receive —
/// the kernel strips it and hands us the ICMP message starting at the ICMP
/// header. So when parsing replies we index from offset 0 of the received bytes
/// as the ICMP header, not from an IP header. (The TTL, which lives in the IP
/// header, is therefore not in the payload and must be read out-of-band via a
/// `recvmsg` control message — see `PingEngine`.)
enum ICMPType {
    static let echoReply: UInt8 = 0    // Echo Reply (the response to our probe)
    static let echoRequest: UInt8 = 8  // Echo Request (what we send)
    static let timeExceeded: UInt8 = 11 // Time Exceeded (TTL hit zero in transit)
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
