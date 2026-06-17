import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

/// Unit coverage for the model boilerplate that `serialization_test` only
/// exercises along its happy path: `toString` branches, `copyWith` (with and
/// without overrides), value equality / `hashCode`, and the `fromMap`/`toMap`
/// edge cases (null fields, missing keys, non-list `errors`).
void main() {
  group('PingError', () {
    test('toString without a message is just the error name', () {
      expect(
        PingError(ErrorType.requestTimedOut).toString(),
        'requestTimedOut',
      );
    });

    test('toString with a message is "<name>: <message>"', () {
      expect(
        PingError(ErrorType.unknown, message: 'boom').toString(),
        'unknown: boom',
      );
    });

    test('copyWith with no args returns an equal value', () {
      final original = PingError(ErrorType.noReply, message: 'm');
      expect(original.copyWith(), equals(original));
    });

    test('copyWith overrides each field', () {
      final updated = PingError(ErrorType.noReply).copyWith(
        error: ErrorType.unknownHost,
        message: 'changed',
      );
      expect(updated.error, ErrorType.unknownHost);
      expect(updated.message, 'changed');
    });

    test('equality, identity and hashCode', () {
      final a = PingError(ErrorType.unknown, message: 'x');
      final b = PingError(ErrorType.unknown, message: 'x');
      final c = PingError(ErrorType.unknown, message: 'y');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a == a, isTrue); // identical fast-path
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(Object())));
    });

    test('toMap serializes the human-readable error message', () {
      expect(
        PingError(ErrorType.timeToLiveExceeded, message: 'm').toMap(),
        {'error': 'Time To Live Exceeded', 'message': 'm'},
      );
    });

    test('fromMap with a missing error falls back to ErrorType.unknown', () {
      expect(PingError.fromMap({}).error, ErrorType.unknown);
    });

    group('ErrorType.fromMessage', () {
      const cases = {
        'Time To Live Exceeded': ErrorType.timeToLiveExceeded,
        'Request Timed Out': ErrorType.requestTimedOut,
        'Unknown Host': ErrorType.unknownHost,
        'No Reply': ErrorType.noReply,
        'Unknown Error': ErrorType.unknown,
        'something unrecognized': ErrorType.unknown, // default branch
      };
      cases.forEach((message, expected) {
        test('maps "$message"', () {
          expect(ErrorType.fromMessage(message), expected);
        });
      });
    });
  });

  group('PingResponse', () {
    test('toString includes only the fields that are set', () {
      expect(PingResponse(seq: 1).toString(), 'PingResponse(seq:1)');
    });

    test('toString renders ip, ttl and time when present', () {
      final str = PingResponse(
        seq: 2,
        ip: '1.2.3.4',
        ttl: 64,
        time: const Duration(milliseconds: 12),
      ).toString();
      expect(str, contains('seq:2'));
      expect(str, contains('ip:1.2.3.4'));
      expect(str, contains('ttl:64'));
      expect(str, contains('time:12.0 ms'));
    });

    test('copyWith with no args returns an equal value', () {
      final original = PingResponse(seq: 1, ttl: 2, ip: '9.9.9.9');
      expect(original.copyWith(), equals(original));
    });

    test('copyWith overrides each field', () {
      final updated = PingResponse(seq: 1).copyWith(
        seq: 5,
        ttl: 10,
        time: const Duration(milliseconds: 3),
        ip: '8.8.8.8',
      );
      expect(updated.seq, 5);
      expect(updated.ttl, 10);
      expect(updated.time, const Duration(milliseconds: 3));
      expect(updated.ip, '8.8.8.8');
    });

    test('equality, identity and hashCode', () {
      final a = PingResponse(seq: 1, ttl: 2, ip: 'x');
      final b = PingResponse(seq: 1, ttl: 2, ip: 'x');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a == a, isTrue);
      expect(a, isNot(equals(PingResponse(seq: 9))));
      expect(a, isNot(equals(Object())));
    });

    test('fromMap tolerates an absent time', () {
      final r = PingResponse.fromMap({'seq': 1, 'ttl': 2, 'ip': 'x'});
      expect(r.time, isNull);
      expect(r.seq, 1);
    });
  });

  group('PingSummary', () {
    test('toString without time or errors', () {
      expect(
        PingSummary(transmitted: 4, received: 3).toString(),
        'PingSummary(transmitted:4, received:3)',
      );
    });

    test('toString appends time and errors when present', () {
      final str = PingSummary(
        transmitted: 4,
        received: 2,
        time: const Duration(milliseconds: 1500),
        errors: [PingError(ErrorType.noReply)],
      ).toString();
      expect(str, contains('time: 1500 ms'));
      expect(str, contains('Errors:'));
      expect(str, contains('noReply'));
    });

    test('copyWith with no args returns an equal value', () {
      final original = PingSummary(
        transmitted: 4,
        received: 3,
        time: const Duration(milliseconds: 1),
        errors: [PingError(ErrorType.unknown)],
      );
      expect(original.copyWith(), equals(original));
    });

    test('copyWith overrides each field', () {
      final updated = PingSummary(transmitted: 1, received: 1).copyWith(
        transmitted: 9,
        received: 8,
        time: const Duration(milliseconds: 7),
        errors: [PingError(ErrorType.noReply)],
      );
      expect(updated.transmitted, 9);
      expect(updated.received, 8);
      expect(updated.time, const Duration(milliseconds: 7));
      expect(updated.errors, hasLength(1));
    });

    test('equality compares the errors list element-wise', () {
      final a = PingSummary(
        transmitted: 1,
        received: 1,
        errors: [PingError(ErrorType.noReply)],
      );
      final b = PingSummary(
        transmitted: 1,
        received: 1,
        errors: [PingError(ErrorType.noReply)],
      );
      final c = PingSummary(
        transmitted: 1,
        received: 1,
        errors: [PingError(ErrorType.unknown)],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a == a, isTrue);
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(Object())));
    });

    test('fromMap applies defaults for missing tx/rx counts', () {
      final s = PingSummary.fromMap({});
      expect(s.transmitted, 0);
      expect(s.received, 0);
      expect(s.time, isNull);
      expect(s.errors, isEmpty);
    });

    test('fromMap treats a non-list errors value as an empty list', () {
      final s = PingSummary.fromMap({
        'transmitted': 2,
        'received': 1,
        'errors': null,
      });
      expect(s.errors, isEmpty);
    });
  });

  group('PingData', () {
    final response = PingResponse(seq: 1, ip: '1.1.1.1');
    final error = PingError(ErrorType.requestTimedOut);
    final summary = PingSummary(transmitted: 1, received: 0);

    test('toString delegates to the summary when present', () {
      final data = PingData(response: response, summary: summary, error: error);
      expect(data.toString(), summary.toString());
    });

    test('toString renders the response+error form when no summary', () {
      final data = PingData(response: response, error: error);
      expect(data.toString(), 'PingError(response:$response, error:$error)');
    });

    test('toString delegates to the response when only a response', () {
      final data = PingData(response: response);
      expect(data.toString(), response.toString());
    });

    test('toString of an empty PingData is "null"', () {
      expect(const PingData().toString(), 'null');
    });

    test('copyWith with no args returns an equal value', () {
      final original = PingData(response: response, error: error);
      expect(original.copyWith(), equals(original));
    });

    test('copyWith overrides each field', () {
      final updated = const PingData().copyWith(
        response: response,
        summary: summary,
        error: error,
      );
      expect(updated.response, response);
      expect(updated.summary, summary);
      expect(updated.error, error);
    });

    test('equality, identity and hashCode', () {
      final a = PingData(response: response, error: error);
      final b = PingData(response: response, error: error);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a == a, isTrue);
      expect(a, isNot(equals(PingData(summary: summary))));
      expect(a, isNot(equals(Object())));
    });

    test('toMap/fromMap round-trips null members as null', () {
      const empty = PingData();
      expect(empty.toMap(), {'response': null, 'summary': null, 'error': null});
      expect(PingData.fromMap(empty.toMap()), equals(empty));
    });
  });
}
