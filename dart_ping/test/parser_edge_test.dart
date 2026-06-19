import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:dart_ping/src/ping/mac_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';
import 'package:test/test.dart';

void main() {
  // Field-level coverage for the TTL-exceeded branch. The bug it guards
  // against: macOS/Windows patterns have no `seq` group, so reading it
  // unconditionally threw "Not a capture group name: seq". These assert the
  // response fields, not just the error type (which parse_test covers).
  group('TTL-exceeded response fields: ', () {
    test('Linux captures both seq and ip', () {
      final res = PingLinux.defaultParser.parse(
        'From 172.17.0.1 (172.17.0.1) icmp_seq=1 Time to live exceeded',
      );
      expect(res?.error?.error, ErrorType.timeToLiveExceeded);
      expect(res?.response?.seq, 1);
      expect(res?.response?.ip, isNotNull);
    });

    test('macOS captures ip with a null seq (no seq group)', () {
      final res = PingMac.defaultParser.parse(
        '92 bytes from 172.17.0.1: Time to live exceeded',
      );
      expect(res?.error?.error, ErrorType.timeToLiveExceeded);
      expect(res?.response?.seq, isNull);
      expect(res?.response?.ip, '172.17.0.1');
    });

    test('Windows captures ip with a null seq (no seq group)', () {
      final res = PingWindows.defaultParser.parse(
        'Reply from 10.20.60.1: TTL expired in transit.',
      );
      expect(res?.error?.error, ErrorType.timeToLiveExceeded);
      expect(res?.response?.seq, isNull);
      expect(res?.response?.ip, '10.20.60.1');
    });
  });

  group('Parser edge cases: ', () {
    test('an unrecognized line parses to null', () {
      expect(PingMac.defaultParser.parse('totally unrelated output'), isNull);
      expect(PingLinux.defaultParser.parse(''), isNull);
    });

    test('an errorStrs match carries the raw line through as the message', () {
      final res =
          PingWindows.defaultParser.parse('General failure.');
      expect(res?.error?.error, ErrorType.unknown);
      expect(res?.error?.message, 'General failure.');
    });

    test('a malformed summary (missing tx/rx) throws', () {
      // A pattern whose tx/rx groups can fail to participate in the match,
      // exercising the parser's defensive guard against a summary line it
      // matched but cannot extract counts from.
      final parser = PingParser(
        responseRgx: RegExp(r'response (?<seq>\d+)'),
        summaryRgx: RegExp(r'X(?<tx>\d+)?Y(?<rx>\d+)?Z'),
        timeoutRgx: RegExp(r'timeout'),
        timeToLiveRgx: RegExp(r'ttl'),
        unknownHostStr: RegExp(r'unknown host'),
      );

      expect(() => parser.parse('XYZ'), throwsA(isA<Exception>()));
    });

    test('a summary with a non-time third group does not throw', () {
      // A custom parser may define a third capturing group that is not
      // `time`; reading the time field must be guarded by group NAME, not by
      // group count, or it throws "Not a capture group name: time".
      final parser = PingParser(
        responseRgx: RegExp(r'response (?<seq>\d+)'),
        summaryRgx: RegExp(r'tx=(?<tx>\d+) rx=(?<rx>\d+) loss=(?<loss>\d+)'),
        timeoutRgx: RegExp(r'timeout'),
        timeToLiveRgx: RegExp(r'ttl'),
        unknownHostStr: RegExp(r'unknown host'),
      );

      final res = parser.parse('tx=4 rx=3 loss=1');
      expect(res?.summary?.transmitted, 4);
      expect(res?.summary?.received, 3);
      expect(res?.summary?.time, isNull);
    });
  });
}
