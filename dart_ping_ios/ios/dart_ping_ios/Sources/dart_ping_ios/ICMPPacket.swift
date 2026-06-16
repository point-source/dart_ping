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
    static let echoReply: UInt8 = 0   // Echo Reply (the response to our probe)
    static let echoRequest: UInt8 = 8 // Echo Request (what we send)
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
enum ICMPPacket {

    /// The fixed-size payload we attach to every Echo Request: an 8-byte
    /// big-endian send timestamp expressed in microseconds since the reference
    /// date. This makes the packet self-describing for debugging and lets a
    /// reply's echoed payload corroborate the engine's own send-time table.
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
    static func echoRequest(identifier: UInt16,
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
    struct EchoReply {
        let identifier: UInt16
        let sequence: UInt16
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
    static func parseEchoReply(_ data: Data) -> EchoReply? {
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

    // MARK: - Checksum

    /// Standard Internet checksum (RFC 1071): the 16-bit one's-complement of the
    /// one's-complement sum of all 16-bit words in the buffer.
    ///
    /// Bytes are summed as big-endian 16-bit words; a trailing odd byte is
    /// padded with a zero low byte. Carries are folded back into the low 16 bits,
    /// and the final result is bit-inverted. The checksum field itself must be
    /// zero in `data` when this is computed.
    static func checksum(_ data: Data) -> UInt16 {
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
