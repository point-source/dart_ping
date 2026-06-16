import Flutter
import UIKit
import XCTest

// We import the plugin module to reach the (now `public`) ICMP framing/parsing
// API in `ICMPPacket.swift`. These tests exercise the deterministic, network-free
// logic only: checksum computation, Echo Request construction, Echo Reply
// parsing, and Time Exceeded original-sequence extraction (§spec:ios-tests).
//
// The wire format is the whole point of this code, so every test documents the
// exact bytes/offsets/endianness it expects and (for the checksum) shows the
// one's-complement arithmetic by hand.
import dart_ping_ios

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  // MARK: - checksum(_:) — RFC 1071 Internet checksum

  /// An all-zero buffer sums to 0; the one's-complement of 0 (over 16 bits) is
  /// 0xFFFF. This is the canonical "no data" checksum value.
  func testChecksumAllZeroBufferIsFFFF() {
    let data = Data(count: 8) // eight zero bytes
    // sum = 0; fold loop is a no-op; ~0 truncated to UInt16 == 0xFFFF.
    XCTAssertEqual(ICMPPacket.checksum(data), 0xFFFF)
  }

  /// A hand-computed even-length buffer with no carry fold.
  ///
  /// Bytes: 0x00 0x01 0xF2 0x03
  ///   word0 = 0x0001
  ///   word1 = 0xF203
  ///   sum   = 0x0001 + 0xF203 = 0xF204   (no bits above bit 15, no fold)
  ///   ~sum  = 0xFFFF - 0xF204 = 0x0DFB
  func testChecksumKnownEvenVector() {
    let data = Data([0x00, 0x01, 0xF2, 0x03])
    XCTAssertEqual(ICMPPacket.checksum(data), 0x0DFB)
  }

  /// An odd-length buffer exercises the trailing-odd-byte path: the final byte
  /// is treated as the HIGH byte of a 16-bit word whose low byte is zero.
  ///
  /// Bytes: 0x12 0x34 0x56
  ///   word0    = 0x1234
  ///   trailing = 0x56 << 8 = 0x5600
  ///   sum      = 0x1234 + 0x5600 = 0x6834   (no fold)
  ///   ~sum     = 0xFFFF - 0x6834 = 0x97CB
  func testChecksumOddLengthTrailingBytePath() {
    let data = Data([0x12, 0x34, 0x56])
    XCTAssertEqual(ICMPPacket.checksum(data), 0x97CB)
  }

  /// A buffer whose 16-bit sum overflows 16 bits, exercising the carry-fold loop.
  ///
  /// Bytes: 0xFF 0xFF 0xFF 0xFF
  ///   word0 = 0xFFFF
  ///   word1 = 0xFFFF
  ///   sum   = 0x0001_FFFE
  ///   fold  = (0xFFFE) + (0x0001) = 0xFFFF
  ///   ~fold = 0x0000
  func testChecksumCarryFoldPath() {
    let data = Data([0xFF, 0xFF, 0xFF, 0xFF])
    XCTAssertEqual(ICMPPacket.checksum(data), 0x0000)
  }

  /// A single trailing byte only (length 1): the trailing-odd-byte path runs
  /// with no preceding full words.
  ///
  /// Bytes: 0x01
  ///   trailing = 0x01 << 8 = 0x0100
  ///   sum      = 0x0100
  ///   ~sum     = 0xFFFF - 0x0100 = 0xFEFF
  func testChecksumSingleByte() {
    let data = Data([0x01])
    XCTAssertEqual(ICMPPacket.checksum(data), 0xFEFF)
  }

  // MARK: - echoRequest(identifier:sequence:sendTimeMicros:)

  /// The produced Echo Request must have the correct length, type/code bytes,
  /// big-endian identifier/sequence at the documented offsets, a big-endian
  /// embedded timestamp in the payload, and a checksum that makes the whole
  /// message checksum-valid (recomputed checksum over the stored bytes == 0).
  func testEchoRequestFramingAndChecksumRoundTrip() {
    let identifier: UInt16 = 0xABCD
    let sequence: UInt16 = 0x1234
    let sendTimeMicros: UInt64 = 0x0102_0304_0506_0708

    let packet = ICMPPacket.echoRequest(identifier: identifier,
                                        sequence: sequence,
                                        sendTimeMicros: sendTimeMicros)

    // Length = 8-byte ICMP echo header + 8-byte payload = 16.
    XCTAssertEqual(packet.count, 16)

    // byte 0: type = 8 (echoRequest); byte 1: code = 0.
    XCTAssertEqual(packet[0], 8)
    XCTAssertEqual(packet[1], 0)

    // bytes 4..5: identifier big-endian (0xAB, 0xCD).
    XCTAssertEqual(packet[4], 0xAB)
    XCTAssertEqual(packet[5], 0xCD)

    // bytes 6..7: sequence big-endian (0x12, 0x34).
    XCTAssertEqual(packet[6], 0x12)
    XCTAssertEqual(packet[7], 0x34)

    // bytes 8..15: timestamp big-endian (most-significant byte first).
    XCTAssertEqual(packet[8], 0x01)
    XCTAssertEqual(packet[9], 0x02)
    XCTAssertEqual(packet[10], 0x03)
    XCTAssertEqual(packet[11], 0x04)
    XCTAssertEqual(packet[12], 0x05)
    XCTAssertEqual(packet[13], 0x06)
    XCTAssertEqual(packet[14], 0x07)
    XCTAssertEqual(packet[15], 0x08)

    // Checksum validity: by the one's-complement property, recomputing the
    // checksum over the full message (with the stored checksum field in place)
    // must yield 0. (sumWithZeroedField + ~sumWithZeroedField folds to 0xFFFF,
    // and ~0xFFFF == 0.)
    XCTAssertEqual(ICMPPacket.checksum(packet), 0x0000)

    // Sanity: the checksum field itself is non-zero for this non-trivial packet
    // (i.e. the field was actually filled in, not left zero).
    let storedChecksum = (UInt16(packet[2]) << 8) | UInt16(packet[3])
    XCTAssertNotEqual(storedChecksum, 0x0000)
  }

  /// The Echo Request must round-trip through `parseEchoReply` only after its
  /// type byte is flipped to Echo Reply (0): an outgoing request is type 8 and
  /// must NOT parse as a reply. This both documents the type discrimination and
  /// confirms identifier/sequence survive a type-0 reframe.
  func testEchoRequestReframedAsReplyParsesIdentifierAndSequence() {
    var packet = ICMPPacket.echoRequest(identifier: 0x00FF,
                                        sequence: 0xBEEF,
                                        sendTimeMicros: 0)

    // As built, it is a type-8 Echo Request and must not parse as a reply.
    XCTAssertNil(ICMPPacket.parseEchoReply(packet))

    // Reframe the type byte to Echo Reply (0); identifier/sequence bytes are
    // untouched, so the parser must recover them big-endian.
    packet[0] = 0 // ICMPType.echoReply
    let reply = ICMPPacket.parseEchoReply(packet)
    XCTAssertNotNil(reply)
    XCTAssertEqual(reply?.identifier, 0x00FF)
    XCTAssertEqual(reply?.sequence, 0xBEEF)
  }

  // MARK: - parseEchoReply(_:)

  /// Builds a minimal valid Echo Reply (8-byte header, type 0) and confirms the
  /// identifier and sequence are extracted big-endian.
  func testParseEchoReplyExtractsBigEndianFields() {
    // type=0, code=0, checksum=0x0000 (ignored by parser), id=0x1122, seq=0x3344
    let data = Data([0x00, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44])
    let reply = ICMPPacket.parseEchoReply(data)
    XCTAssertNotNil(reply)
    XCTAssertEqual(reply?.identifier, 0x1122)
    XCTAssertEqual(reply?.sequence, 0x3344)
  }

  /// Buffers shorter than the 8-byte ICMP header are rejected.
  func testParseEchoReplyRejectsTooShort() {
    let sevenBytes = Data([0x00, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33])
    XCTAssertNil(ICMPPacket.parseEchoReply(sevenBytes))
    XCTAssertNil(ICMPPacket.parseEchoReply(Data()))
  }

  /// A non-Echo-Reply type byte is rejected even when long enough (here type 8,
  /// an Echo Request, and type 11, Time Exceeded).
  func testParseEchoReplyRejectsWrongType() {
    let echoRequest = Data([0x08, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44])
    XCTAssertNil(ICMPPacket.parseEchoReply(echoRequest))

    let timeExceeded = Data([0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    XCTAssertNil(ICMPPacket.parseEchoReply(timeExceeded))
  }

  /// The parser is written base-relative (uses `data.startIndex`), so it must
  /// work on a Data SLICE with a non-zero startIndex. We prepend 4 junk bytes
  /// and slice them off; the slice keeps the original (non-zero) startIndex.
  func testParseEchoReplyWorksOnSliceWithNonZeroStartIndex() {
    var backing = Data([0xDE, 0xAD, 0xBE, 0xEF]) // junk prefix
    backing.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x55, 0x66, 0x77, 0x88])
    let slice = backing.suffix(from: 4) // startIndex == 4, not 0

    // Guard the premise of the test: this is genuinely a non-zero-based slice.
    XCTAssertEqual(slice.startIndex, 4)

    let reply = ICMPPacket.parseEchoReply(slice)
    XCTAssertNotNil(reply)
    XCTAssertEqual(reply?.identifier, 0x5566)
    XCTAssertEqual(reply?.sequence, 0x7788)
  }

  // MARK: - parseTimeExceededOriginalSequence(_:)

  /// Helper: build a synthetic Time Exceeded (type 11) message that quotes an
  /// original IPv4 packet whose ICMP Echo header carries `originalSequence`.
  ///
  /// Layout produced:
  ///   [0..7]            type-11 ICMP header (type=11, code=0, csum=0, 4 unused)
  ///   [8 .. 8+ipLen-1]  quoted original IPv4 header (firstByte=0x40|ihl)
  ///   [.. +8]           quoted original ICMP Echo header (8 bytes); its
  ///                     sequence field (offset +6) holds `originalSequence`.
  private func makeTimeExceeded(ihl: UInt8,
                                originalSequence: UInt16,
                                truncateQuotedEchoTo: Int? = nil) -> Data {
    var data = Data()
    // type-11 ICMP header: type=11, code=0, checksum=0x0000, 4 unused bytes.
    data.append(contentsOf: [0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    // Quoted original IPv4 header. First byte = version(4) << 4 | IHL.
    // We only care that byte 0's low nibble is the IHL; fill the rest with 0xAA.
    let ipHeaderLength = Int(ihl) * 4
    var ipHeader = Data([0x40 | ihl])
    if ipHeaderLength > 1 {
      ipHeader.append(contentsOf: Array(repeating: 0xAA, count: ipHeaderLength - 1))
    }
    data.append(ipHeader)

    // Quoted original ICMP Echo header: type=8, code=0, csum=0, id=0x0000,
    // sequence=originalSequence (big-endian at offset +6).
    var quotedEcho = Data([0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
                           UInt8(truncatingIfNeeded: originalSequence >> 8),
                           UInt8(truncatingIfNeeded: originalSequence)])
    if let limit = truncateQuotedEchoTo {
      quotedEcho = quotedEcho.prefix(limit)
    }
    data.append(quotedEcho)

    return data
  }

  /// Standard case: a type-11 message quoting an IHL=5 (20-byte) IPv4 header and
  /// an original Echo header with sequence 0x2A2B. The original sequence must be
  /// recovered from offset 8 + 20 + 6.
  func testParseTimeExceededRecoversOriginalSequence() {
    let data = makeTimeExceeded(ihl: 5, originalSequence: 0x2A2B)
    XCTAssertEqual(ICMPPacket.parseTimeExceededOriginalSequence(data), 0x2A2B)
  }

  /// Non-standard IHL with IP options (IHL=6 → 24-byte IP header). The parser
  /// must honor the IHL field when locating the quoted Echo header.
  func testParseTimeExceededHandlesIPOptionsIHL6() {
    let data = makeTimeExceeded(ihl: 6, originalSequence: 0x7F80)
    XCTAssertEqual(ICMPPacket.parseTimeExceededOriginalSequence(data), 0x7F80)
  }

  /// Wrong outer type (here type 0, Echo Reply) is rejected.
  func testParseTimeExceededRejectsWrongType() {
    var data = makeTimeExceeded(ihl: 5, originalSequence: 0x0001)
    data[0] = 0x00 // flip type 11 -> 0
    XCTAssertNil(ICMPPacket.parseTimeExceededOriginalSequence(data))
  }

  /// Too short for even the 8-byte type-11 header is rejected.
  func testParseTimeExceededRejectsTooShortForHeader() {
    let data = Data([0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // only 7 bytes
    XCTAssertNil(ICMPPacket.parseTimeExceededOriginalSequence(data))
  }

  /// An IHL implying fewer than 20 bytes (IHL=4 → 16 bytes) is rejected, since a
  /// valid IPv4 header is at least 20 bytes.
  func testParseTimeExceededRejectsIHLBelowMinimum() {
    // Build manually: type-11 header + a 16-byte "IP header" (IHL=4) + echo.
    var data = Data([0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    data.append(0x40 | 0x04) // version 4, IHL 4 => 16 bytes
    data.append(contentsOf: Array(repeating: 0xAA, count: 15))
    data.append(contentsOf: [0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34])
    XCTAssertNil(ICMPPacket.parseTimeExceededOriginalSequence(data))
  }

  /// The type-11 header is present but there is no quoted IP header byte at all
  /// (exactly 8 bytes): rejected because there is nothing to read the IHL from.
  func testParseTimeExceededRejectsMissingIPHeaderByte() {
    let data = Data([0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // exactly 8
    XCTAssertNil(ICMPPacket.parseTimeExceededOriginalSequence(data))
  }

  /// Truncation before the quoted Echo sequence field is reached: a valid IHL=5
  /// header is quoted, but the quoted Echo header is cut to 6 bytes (it never
  /// reaches the sequence at offset +6/+7), so the parser must return nil.
  func testParseTimeExceededRejectsTruncatedBeforeSequence() {
    let data = makeTimeExceeded(ihl: 5, originalSequence: 0x9999, truncateQuotedEchoTo: 6)
    XCTAssertNil(ICMPPacket.parseTimeExceededOriginalSequence(data))
  }

  /// Base-relative correctness for the Time Exceeded parser too: it must work on
  /// a slice with a non-zero startIndex.
  func testParseTimeExceededWorksOnSliceWithNonZeroStartIndex() {
    var backing = Data([0xDE, 0xAD]) // junk prefix
    backing.append(makeTimeExceeded(ihl: 5, originalSequence: 0x4243))
    let slice = backing.suffix(from: 2)
    XCTAssertEqual(slice.startIndex, 2)
    XCTAssertEqual(ICMPPacket.parseTimeExceededOriginalSequence(slice), 0x4243)
  }

}
