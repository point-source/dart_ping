import FlutterMacOS
import Cocoa
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
    // IHL=4 => a 16-byte quoted IP header, below the 20-byte IPv4 minimum.
    let data = makeTimeExceeded(ihl: 4, originalSequence: 0x1234)
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

  // MARK: - stripIPv4Header(_:)
  //
  // Regression coverage for the Darwin receive path: a SOCK_DGRAM/IPPROTO_ICMP
  // socket on macOS/iOS hands us the FULL IPv4 header ahead of the ICMP message
  // (unlike Linux). The engine must strip it before parsing, otherwise the IP
  // header's first byte (0x45) is read as the ICMP type, no reply ever matches,
  // and every probe times out. These tests pin that wire layout down.

  /// Helper: build a Darwin-style received IPv4 datagram = a 20-byte IPv4 header
  /// (with `ttl` at offset 8) followed by `payload` (the ICMP message).
  private func makeIPv4Datagram(ttl: UInt8, ihl: UInt8 = 5, payload: Data) -> Data {
    let ipHeaderLength = Int(ihl) * 4
    var header = Data(repeating: 0xAA, count: ipHeaderLength)
    header[0] = 0x40 | ihl // version 4 in the high nibble, IHL in the low nibble
    header[8] = ttl        // IPv4 TTL field lives at offset 8
    return header + payload
  }

  /// End-to-end regression: an Echo Reply wrapped in a real IPv4 header must,
  /// after stripping, parse back to the original identifier/sequence and surface
  /// the IP header's TTL. This is the exact shape that previously timed out.
  func testStripIPv4HeaderThenParseEchoReplyRecoversFields() {
    // type=0 (Echo Reply), code=0, csum=0, id=0x1A2B, seq=0x0007
    let echoReply = Data([0x00, 0x00, 0x00, 0x00, 0x1A, 0x2B, 0x00, 0x07])
    let datagram = makeIPv4Datagram(ttl: 115, payload: echoReply)

    let stripped = ICMPPacket.stripIPv4Header(datagram)
    XCTAssertNotNil(stripped)
    XCTAssertEqual(stripped?.ttl, 115)
    XCTAssertEqual(stripped?.icmpMessage.count, 8)

    let reply = stripped.flatMap { ICMPPacket.parseEchoReply($0.icmpMessage) }
    XCTAssertNotNil(reply)
    XCTAssertEqual(reply?.identifier, 0x1A2B)
    XCTAssertEqual(reply?.sequence, 0x0007)
  }

  /// The IHL field must be honored: an IPv4 header carrying options (IHL=6 →
  /// 24 bytes) must be skipped in full so the ICMP message is found intact.
  func testStripIPv4HeaderHonorsIHLWithOptions() {
    let echoReply = Data([0x00, 0x00, 0x00, 0x00, 0xCA, 0xFE, 0x12, 0x34])
    let datagram = makeIPv4Datagram(ttl: 64, ihl: 6, payload: echoReply)

    let stripped = ICMPPacket.stripIPv4Header(datagram)
    XCTAssertEqual(stripped?.ttl, 64)
    XCTAssertEqual(stripped?.icmpMessage, echoReply)
  }

  /// Non-IPv4 version nibble is rejected (here 0x6_ , an IPv6-looking first byte).
  func testStripIPv4HeaderRejectsNonIPv4Version() {
    var datagram = makeIPv4Datagram(ttl: 1, payload: Data(repeating: 0, count: 8))
    datagram[0] = 0x60 // version 6 in the high nibble
    XCTAssertNil(ICMPPacket.stripIPv4Header(datagram))
  }

  /// An IHL implying fewer than 20 bytes (IHL=4 → 16) is rejected: below the
  /// IPv4 minimum header size.
  func testStripIPv4HeaderRejectsIHLBelowMinimum() {
    // 20 bytes total so the length precondition passes, but byte0 claims IHL=4.
    var datagram = Data(repeating: 0xAA, count: 20)
    datagram[0] = 0x44 // version 4, IHL 4 (=16 bytes, too small)
    XCTAssertNil(ICMPPacket.stripIPv4Header(datagram))
  }

  /// Buffers too short to even contain a minimum IPv4 header are rejected.
  func testStripIPv4HeaderRejectsTooShort() {
    XCTAssertNil(ICMPPacket.stripIPv4Header(Data(repeating: 0x45, count: 19)))
    XCTAssertNil(ICMPPacket.stripIPv4Header(Data()))
  }

  /// A datagram that is exactly the IP header with no ICMP bytes after it is
  /// rejected (there is no ICMP message to hand back).
  func testStripIPv4HeaderRejectsNoPayload() {
    let headerOnly = makeIPv4Datagram(ttl: 50, payload: Data())
    XCTAssertEqual(headerOnly.count, 20)
    XCTAssertNil(ICMPPacket.stripIPv4Header(headerOnly))
  }

  /// Base-relative correctness: stripping must work on a slice with a non-zero
  /// startIndex (the engine builds `Data` from an array slice).
  func testStripIPv4HeaderWorksOnSliceWithNonZeroStartIndex() {
    let echoReply = Data([0x00, 0x00, 0x00, 0x00, 0x77, 0x88, 0x99, 0xAA])
    var backing = Data([0xDE, 0xAD, 0xBE]) // junk prefix
    backing.append(makeIPv4Datagram(ttl: 99, payload: echoReply))
    let slice = backing.suffix(from: 3)
    XCTAssertEqual(slice.startIndex, 3)

    let stripped = ICMPPacket.stripIPv4Header(slice)
    XCTAssertEqual(stripped?.ttl, 99)
    XCTAssertEqual(stripped.flatMap { ICMPPacket.parseEchoReply($0.icmpMessage) }?.sequence, 0x99AA)
  }

  // MARK: - §spec:address-family-error-honesty (#69-3)

  // The honest error classification and ICMPv6 framing/parsing are the wire
  // contract for IPv6 support, so each test pins the exact bytes/offsets and the
  // exact getaddrinfo/errno -> PingErrorKind mapping. These run network-free.

  // MARK: errorKind(forGetaddrinfoStatus:)

  /// A genuine name-resolution miss (EAI_NONAME) is an Unknown Host, NOT a route
  /// problem — the honesty boundary the spec draws.
  func testGetaddrinfoNoNameMapsToUnknownHost() {
    XCTAssertEqual(PingEngine.errorKind(forGetaddrinfoStatus: EAI_NONAME), .unknownHost)
  }

  /// An address-family mismatch (EAI_ADDRFAMILY) — the host has no address of
  /// the selected family — is the route/family failure, surfaced as .noRoute.
  func testGetaddrinfoAddrFamilyMapsToNoRoute() {
    XCTAssertEqual(PingEngine.errorKind(forGetaddrinfoStatus: EAI_ADDRFAMILY), .noRoute)
  }

  /// EAI_NODATA — the name resolves but has no record of the selected family —
  /// is an address-family failure (.noRoute), not a name miss (#69).
  func testGetaddrinfoNoDataMapsToNoRoute() {
    XCTAssertEqual(PingEngine.errorKind(forGetaddrinfoStatus: EAI_NODATA), .noRoute)
  }

  // MARK: errorKind(forSendErrno:)

  /// ENETUNREACH on send (no route for this family) maps to .noRoute, the honest
  /// "the selected family can't be reached here" signal.
  func testSendErrnoNetUnreachMapsToNoRoute() {
    XCTAssertEqual(PingEngine.errorKind(forSendErrno: ENETUNREACH), .noRoute)
  }

  /// An unrelated errno (EPERM) is NOT a route problem and stays the catch-all
  /// .unknown, so we don't over-claim "No Route".
  func testSendErrnoArbitraryMapsToUnknown() {
    XCTAssertEqual(PingEngine.errorKind(forSendErrno: EPERM), .unknown)
  }

  // MARK: ICMPv6 framing/parsing

  /// The ICMPv6 Echo Request first byte is type 128 (RFC 4443), the identifier
  /// and sequence are big-endian at the shared offsets 4..5 / 6..7, and the
  /// checksum field (bytes 2..3) is left ZERO (the kernel fills it on the
  /// SOCK_DGRAM path).
  func testEchoRequestV6FramingTypeAndZeroChecksum() {
    let packet = ICMPPacket.echoRequestV6(identifier: 0xABCD,
                                          sequence: 0x1234,
                                          sendTimeMicros: 0x0102_0304_0506_0708)

    // 8-byte ICMPv6 echo header + 8-byte payload = 16.
    XCTAssertEqual(packet.count, 16)

    // byte 0: type = 128 (ICMPv6 echo request); byte 1: code = 0.
    XCTAssertEqual(packet[0], 128)
    XCTAssertEqual(packet[1], 0)

    // bytes 2..3: checksum left zero (kernel computes it over the pseudo-header).
    XCTAssertEqual(packet[2], 0x00)
    XCTAssertEqual(packet[3], 0x00)

    // bytes 4..5: identifier big-endian; bytes 6..7: sequence big-endian.
    XCTAssertEqual(packet[4], 0xAB)
    XCTAssertEqual(packet[5], 0xCD)
    XCTAssertEqual(packet[6], 0x12)
    XCTAssertEqual(packet[7], 0x34)

    // bytes 8..15: timestamp big-endian (most-significant byte first).
    XCTAssertEqual(packet[8], 0x01)
    XCTAssertEqual(packet[15], 0x08)
  }

  /// A type-129 ICMPv6 Echo Reply parses identifier/sequence big-endian, and a
  /// type-128 request does NOT parse as a reply (type discrimination).
  func testParseEchoReplyV6RecoversSequence() {
    // type=129, code=0, csum=0x0000, id=0x1122, seq=0x3344
    let data = Data([0x81, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44])
    let reply = ICMPPacket.parseEchoReplyV6(data)
    XCTAssertNotNil(reply)
    XCTAssertEqual(reply?.identifier, 0x1122)
    XCTAssertEqual(reply?.sequence, 0x3344)

    // A type-128 request must NOT parse as a v6 reply.
    let request = ICMPPacket.echoRequestV6(identifier: 0, sequence: 0, sendTimeMicros: 0)
    XCTAssertNil(ICMPPacket.parseEchoReplyV6(request))
  }

  /// A type-3 ICMPv6 Time Exceeded message quotes a FIXED 40-byte IPv6 header
  /// then the original echo; the original sequence lives at offset 8 + 40 + 6.
  func testParseTimeExceededV6RecoversOriginalSequence() {
    var data = Data()
    // type-3 ICMPv6 header: type=3, code=0, checksum=0x0000, 4 unused bytes.
    data.append(contentsOf: [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    // Quoted original IPv6 header: a fixed 40 bytes (contents irrelevant here).
    data.append(Data(repeating: 0xAA, count: 40))
    // Quoted original ICMPv6 Echo header: type=128, code=0, csum=0, id=0,
    // sequence=0x2A2B big-endian at offset +6.
    data.append(contentsOf: [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2A, 0x2B])

    XCTAssertEqual(ICMPPacket.parseTimeExceededOriginalSequenceV6(data), 0x2A2B)

    // Truncated before the quoted echo's sequence field -> nil.
    let truncated = data.prefix(8 + 40 + 6)
    XCTAssertNil(ICMPPacket.parseTimeExceededOriginalSequenceV6(truncated))
  }

  // MARK: - §spec:nat64-tests — NAT64 synthesis decision + honest-error fallback
  //
  // The NAT64 reachability fix (#52) un-pins the resolve for the ONE narrow case
  // of an IPv4 literal under IpVersion.ipv4 with synthesis enabled. The decision
  // itself (`shouldSynthesize`/`isIPv4Literal`) and the honest error
  // classification on the synthesis-failure path are pure/static, so they are
  // pinned here WITHOUT a live process — a real IPv6-only NAT64 cellular network
  // is not reproducible on a hosted runner or the simulator, so the end-to-end
  // reachability leg is an on-device acceptance step (§spec:nat64-literal-synthesis,
  // §spec:nat64-error-fallback). These offline seams are the testable surface.

  // MARK: shouldSynthesize(family:nat64Synthesis:host:) — the SOLE relaxation gate

  /// The relaxation engages ONLY for an IPv4 literal, IpVersion.ipv4, synthesis
  /// enabled — the single previously-broken path. Offline: this is the pure
  /// decision the engine consults before un-pinning the resolve; no socket needed.
  func testShouldSynthesizeTrueForIPv4LiteralWithSynthesisEnabled() {
    XCTAssertTrue(PingEngine.shouldSynthesize(family: .v4, nat64Synthesis: true, host: "13.35.27.1"))
    // A second IPv4 literal: still engaged.
    XCTAssertTrue(PingEngine.shouldSynthesize(family: .v4, nat64Synthesis: true, host: "1.1.1.1"))
  }

  /// Every other combination keeps #69's pinned, raw resolve. Offline rationale:
  /// the gate is the whole behavioral boundary, so each disqualifying input is
  /// pinned here rather than discovered on an (unavailable) live NAT64 network.
  func testShouldSynthesizeFalseForEveryNonEngagedCase() {
    // Synthesis disabled (opt-out) -> raw, family-pinned path even for a literal.
    XCTAssertFalse(PingEngine.shouldSynthesize(family: .v4, nat64Synthesis: false, host: "13.35.27.1"))
    // IpVersion.ipv6 selection is unaffected by the IPv4-literal relaxation.
    XCTAssertFalse(PingEngine.shouldSynthesize(family: .v6, nat64Synthesis: true, host: "13.35.27.1"))
    // A hostname already gets DNS64 from the system resolver; not this gate.
    XCTAssertFalse(PingEngine.shouldSynthesize(family: .v4, nat64Synthesis: true, host: "example.com"))
    // An IPv6 literal is not an IPv4 literal; no synthesis.
    XCTAssertFalse(PingEngine.shouldSynthesize(family: .v4, nat64Synthesis: true, host: "2001:4860:4860::8888"))
  }

  // MARK: isIPv4Literal(_:)

  /// Dotted-quads are IPv4 literals (inet_pton(AF_INET) accepts them). Offline:
  /// purely numeric classification, no DNS, no socket (§spec:nat64-tests).
  func testIsIPv4LiteralTrueForDottedQuads() {
    XCTAssertTrue(PingEngine.isIPv4Literal("13.35.27.1"))
    XCTAssertTrue(PingEngine.isIPv4Literal("0.0.0.0"))
    XCTAssertTrue(PingEngine.isIPv4Literal("255.255.255.255"))
  }

  /// Hostnames, IPv6 literals, the empty string, and a malformed quad (an octet
  /// > 255) are NOT IPv4 literals, so they never trip the synthesis gate. Offline:
  /// inet_pton rejects each form deterministically with no network.
  func testIsIPv4LiteralFalseForNonLiterals() {
    XCTAssertFalse(PingEngine.isIPv4Literal("example.com"))
    XCTAssertFalse(PingEngine.isIPv4Literal("2001:4860:4860::8888"))
    XCTAssertFalse(PingEngine.isIPv4Literal(""))
    XCTAssertFalse(PingEngine.isIPv4Literal("999.1.1.1")) // 999 > 255: malformed
  }

  // MARK: honest error classification on the synthesis-failure path
  // (§spec:nat64-error-fallback)
  //
  // When synthesis cannot produce a routable address, the engine must fall back
  // to #69's honest typed error: an address-family / route failure becomes
  // .noRoute, and .unknownHost is reserved for a GENUINE name miss — never a
  // phantom unknownHost for a routing failure, never a silent hang. These reuse
  // the EXISTING #69 helpers (`errorKind(forGetaddrinfoStatus:)` /
  // `errorKind(forSendErrno:)`); this test documents that those same classifications
  // hold on the NAT64 synthesis fallback path. Offline: a pure status/errno ->
  // PingErrorKind mapping, asserted without a live NAT64 network.

  /// getaddrinfo statuses reachable when the un-pinned (AF_UNSPEC) synthesis
  /// resolve yields no usable/family-appropriate record map to .noRoute, while a
  /// genuine name miss stays .unknownHost — the honesty boundary #52 must keep.
  func testSynthesisFallbackGetaddrinfoStatusesClassifyHonestly() {
    // No record of a usable family for the resolved literal -> route/family fail.
    XCTAssertEqual(PingEngine.errorKind(forGetaddrinfoStatus: EAI_NODATA), .noRoute)
    XCTAssertEqual(PingEngine.errorKind(forGetaddrinfoStatus: EAI_ADDRFAMILY), .noRoute)
    XCTAssertEqual(PingEngine.errorKind(forGetaddrinfoStatus: EAI_FAMILY), .noRoute)
    // A genuine name miss is the ONLY thing that stays unknownHost (never phantom).
    XCTAssertEqual(PingEngine.errorKind(forGetaddrinfoStatus: EAI_NONAME), .unknownHost)
  }

  /// send(2) errnos for the synthesized/route-failed destination all classify as
  /// .noRoute — the honest "this family can't be reached here" signal #52 falls
  /// back to when synthesis does not yield a routable path.
  func testSynthesisFallbackSendErrnosClassifyAsNoRoute() {
    XCTAssertEqual(PingEngine.errorKind(forSendErrno: ENETUNREACH), .noRoute)
    XCTAssertEqual(PingEngine.errorKind(forSendErrno: EHOSTUNREACH), .noRoute)
    XCTAssertEqual(PingEngine.errorKind(forSendErrno: EAFNOSUPPORT), .noRoute)
    XCTAssertEqual(PingEngine.errorKind(forSendErrno: EADDRNOTAVAIL), .noRoute)
  }

  // MARK: synthesizedTransport(hasIPv4:hasIPv6:) — the address-selection policy
  // (§spec:nat64-literal-synthesis / §spec:nat64-tests)
  //
  // The un-pinned (AF_UNSPEC) resolve may return BOTH the synthesized IPv6
  // (NAT64) address and the original IPv4 literal. The engine must NOT commit to
  // whichever entry getaddrinfo sorted first — on an IPv6-only network the IPv4
  // literal is unroutable, and picking it would silently defeat #52. This pure
  // policy encodes the routable-family preference; it is the offline seam over
  // the synthesis address selection (a live IPv6-only NAT64 network is not
  // reproducible on a hosted runner / the simulator).

  /// Both families synthesized -> prefer IPv6 (the routable NAT64 address). This
  /// is the exact #52 case: a bare IPv4 literal on an IPv6-only network where the
  /// resolver returns the synthesized v6 alongside the original (unroutable) v4.
  func testSynthesizedTransportPrefersIPv6WhenBothPresent() {
    XCTAssertEqual(PingEngine.synthesizedTransport(hasIPv4: true, hasIPv6: true), .v6)
    // IPv6 alone (pure synthesis) is also v6.
    XCTAssertEqual(PingEngine.synthesizedTransport(hasIPv4: false, hasIPv6: true), .v6)
  }

  /// No IPv6 synthesized (dual-stack / Wi-Fi, where the literal already routes)
  /// -> send over IPv4, unchanged from the pre-#52 behavior.
  func testSynthesizedTransportUsesIPv4WhenNoIPv6() {
    XCTAssertEqual(PingEngine.synthesizedTransport(hasIPv4: true, hasIPv6: false), .v4)
  }

  /// Resolver returned no usable address -> nil, which the resolve path maps to
  /// the honest `.noRoute` (never a phantom unknownHost, never a hang).
  func testSynthesizedTransportNilWhenNeitherPresent() {
    XCTAssertNil(PingEngine.synthesizedTransport(hasIPv4: false, hasIPv6: false))
  }

}
