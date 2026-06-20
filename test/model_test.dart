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
        {
          'type': 'error',
          'error': 'Time To Live Exceeded',
          'message': 'm',
          'seq': null,
          'ip': null,
          'stats': null,
        },
      );
    });

    test('toString appends seq and ip when present', () {
      expect(
        PingError(ErrorType.timeToLiveExceeded, seq: 3, ip: '1.2.3.4')
            .toString(),
        'timeToLiveExceeded, seq:3, ip:1.2.3.4',
      );
    });

    test('copyWith overrides seq and ip', () {
      final updated = PingError(ErrorType.requestTimedOut)
          .copyWith(seq: 5, ip: '9.9.9.9');
      expect(updated.seq, 5);
      expect(updated.ip, '9.9.9.9');
    });

    test('equality distinguishes seq/ip', () {
      final a = PingError(ErrorType.requestTimedOut, seq: 1);
      final b = PingError(ErrorType.requestTimedOut, seq: 2);
      expect(a, isNot(equals(b)));
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
        'PingSummary(transmitted:4, received:3, loss:25.0%)',
      );
    });

    test('toString appends time, loss and errors when present', () {
      final str = PingSummary(
        transmitted: 4,
        received: 2,
        time: const Duration(milliseconds: 1500),
        errors: [PingError(ErrorType.noReply)],
      ).toString();
      expect(str, contains('loss:50.0%'));
      expect(str, contains('time: 1500 ms'));
      expect(str, contains('Errors:'));
      expect(str, contains('noReply'));
    });

    test('packetLoss is derived from the counts', () {
      expect(PingSummary(transmitted: 10, received: 7).packetLoss, 30.0);
      expect(PingSummary(transmitted: 4, received: 0).packetLoss, 100.0);
      expect(PingSummary(transmitted: 0, received: 0).packetLoss, 100.0);
    });

    test('copyWith carries stats over and overrides it', () {
      final stats = RoundTripStats.fromSamples(
        [const Duration(milliseconds: 1), const Duration(milliseconds: 3)],
      );
      final original = PingSummary(transmitted: 2, received: 2, stats: stats);
      expect(original.copyWith().stats, stats);
      final other = RoundTripStats.fromSamples([const Duration(seconds: 1)]);
      expect(original.copyWith(stats: other).stats, other);
    });

    test('equality and toMap include stats', () {
      final stats = RoundTripStats.fromSamples([const Duration(milliseconds: 5)]);
      final a = PingSummary(transmitted: 1, received: 1, stats: stats);
      final b = PingSummary(transmitted: 1, received: 1, stats: stats);
      final c = PingSummary(transmitted: 1, received: 1);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.toMap()['stats'], stats.toMap());
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

  group('PingEvent', () {
    test('fromMap dispatches on the type discriminator', () {
      expect(
        PingEvent.fromMap(PingResponse(seq: 1, ip: '1.1.1.1').toMap()),
        isA<PingResponse>(),
      );
      expect(
        PingEvent.fromMap(PingError(ErrorType.requestTimedOut).toMap()),
        isA<PingError>(),
      );
      expect(
        PingEvent.fromMap(PingSummary(transmitted: 1, received: 0).toMap()),
        isA<PingSummary>(),
      );
    });

    test('fromMap throws on an unknown type', () {
      expect(
        () => PingEvent.fromMap({'type': 'bogus'}),
        throwsArgumentError,
      );
    });
  });
}
