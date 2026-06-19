import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping_ios/src/ping_event_mapper.dart';
import 'package:test/test.dart';

void main() {
  // --- mapNativeEvent: pure native-map -> bare sealed PingEvent (no stats) ---
  //
  // The native `time` field is carried in MICROSECONDS over the channel, exactly
  // as PingResponse.fromMap / PingSummary.fromMap decode it (§spec:stats-precision).
  group('mapNativeEvent', () {
    test('maps a response event to a PingResponse (microsecond time)', () {
      final event = mapNativeEvent({
        'id': 'run-1',
        'type': 'response',
        'seq': 3,
        'ttl': 55,
        'time': 12000, // microseconds == 12 ms
        'ip': '1.2.3.4',
      });

      expect(event, isA<PingResponse>());
      final response = event as PingResponse;
      expect(response.seq, 3);
      expect(response.ttl, 55);
      expect(response.time, const Duration(microseconds: 12000));
      expect(response.ip, '1.2.3.4');
      // The bare mapper attaches no running stats; that is layered on by
      // NativeEventStatsMapper.
      expect(response.stats, isNull);
    });

    test('preserves sub-millisecond round-trip resolution', () {
      // 1500 microseconds == 1.5 ms: must NOT collapse to a whole millisecond.
      final response = mapNativeEvent({
        'id': 'run-1',
        'type': 'response',
        'seq': 1,
        'time': 1500,
        'ip': '1.2.3.4',
      }) as PingResponse;

      expect(response.time, const Duration(microseconds: 1500));
      expect(response.time!.inMilliseconds, 1); // truncates, but the µs survive
    });

    test('maps a requestTimedOut error to a single PingError carrying seq', () {
      final event = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Request Timed Out',
        'seq': 4,
      });

      // The sealed model has no combined response+error: a timed-out probe is
      // ONE PingError that carries its own seq.
      expect(event, isA<PingError>());
      final error = event as PingError;
      expect(error.error, ErrorType.requestTimedOut);
      expect(error.seq, 4);
      expect(error.ip, isNull);
    });

    test('maps a timeToLiveExceeded error carrying seq + hop ip', () {
      final error = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Time To Live Exceeded',
        'seq': 7,
        'ip': '10.0.0.1',
      }) as PingError;

      expect(error.error, ErrorType.timeToLiveExceeded);
      expect(error.seq, 7);
      expect(error.ip, '10.0.0.1');
    });

    test('maps an unknownHost error with no probe context', () {
      final error = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Unknown Host',
      }) as PingError;

      expect(error.error, ErrorType.unknownHost);
      expect(error.seq, isNull);
      expect(error.ip, isNull);
    });

    test('maps an unknown error via the catch-all', () {
      final error = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Unknown Error',
      }) as PingError;

      expect(error.error, ErrorType.unknown);
    });

    test('maps a standalone noReply error', () {
      final error = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'No Reply',
      }) as PingError;

      expect(error.error, ErrorType.noReply);
      expect(error.seq, isNull);
    });

    test('maps a standalone noRoute error (#69-3)', () {
      // The native engine emits 'No Route' when resolution/send for the SELECTED
      // family is impossible. It must land as ErrorType.noRoute, distinct from
      // unknownHost.
      final error = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'No Route',
      }) as PingError;

      expect(error.error, ErrorType.noRoute);
    });

    test('carries the native message string through to PingError.message', () {
      final error = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Unknown Error',
        'message': 'socket failure',
      }) as PingError;

      expect(error.error, ErrorType.unknown);
      expect(error.message, 'socket failure');
    });

    test('a TTL-exceeded error with ip but no seq keeps ip, null seq', () {
      final error = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Time To Live Exceeded',
        'ip': '192.168.1.1',
      }) as PingError;

      expect(error.error, ErrorType.timeToLiveExceeded);
      expect(error.ip, '192.168.1.1');
      expect(error.seq, isNull);
    });

    test('maps a summary event WITH a time (microseconds)', () {
      final event = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 5,
        'received': 4,
        'time': 5000000, // microseconds == 5 s
      });

      expect(event, isA<PingSummary>());
      final summary = event as PingSummary;
      expect(summary.transmitted, 5);
      expect(summary.received, 4);
      expect(summary.time, const Duration(seconds: 5));
      expect(summary.errors, isEmpty);
    });

    test('maps a summary event WITHOUT a time (null)', () {
      final summary = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 2,
        'received': 0,
        'time': null,
      }) as PingSummary;

      expect(summary.transmitted, 2);
      expect(summary.received, 0);
      expect(summary.time, isNull);
      expect(summary.errors, isEmpty);
    });

    test('maps a summary carrying a mix of errors, in order', () {
      final summary = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 5,
        'received': 0,
        'time': 5000000,
        'errors': [
          {'error': 'Time To Live Exceeded', 'message': null},
          {'error': 'Request Timed Out', 'message': null},
          {'error': 'Unknown Host', 'message': null},
          {'error': 'No Reply', 'message': null},
          {'error': 'Unknown Error', 'message': null},
        ],
      }) as PingSummary;

      expect(
        summary.errors.map((e) => e.error).toList(),
        const <ErrorType>[
          ErrorType.timeToLiveExceeded,
          ErrorType.requestTimedOut,
          ErrorType.unknownHost,
          ErrorType.noReply,
          ErrorType.unknown,
        ],
      );
    });

    test('maps a summary with an explicitly empty errors list to []', () {
      final summary = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 3,
        'received': 3,
        'time': 3000000,
        'errors': <dynamic>[],
      }) as PingSummary;

      expect(summary.errors, isEmpty);
    });

    test('returns null for an unknown type', () {
      expect(mapNativeEvent({'id': 'run-1', 'type': 'something-else'}), isNull);
    });

    test('maps a response event missing ttl/time/ip without throwing', () {
      final response = mapNativeEvent({
        'id': 'run-1',
        'type': 'response',
        'seq': 1,
      }) as PingResponse;

      expect(response.seq, 1);
      expect(response.ttl, isNull);
      expect(response.time, isNull);
      expect(response.ip, isNull);
    });

    // --- channel codec shape: Map<dynamic, dynamic> coercion ---

    test('coerces a genuine Map<dynamic, dynamic> response from the codec', () {
      final Map<dynamic, dynamic> event = <dynamic, dynamic>{
        'id': 'run-1',
        'type': 'response',
        'seq': 6,
        'ttl': 64,
        'time': 21000,
        'ip': '8.8.8.8',
      };

      final response = mapNativeEvent(event) as PingResponse;
      expect(response.seq, 6);
      expect(response.ttl, 64);
      expect(response.time, const Duration(microseconds: 21000));
      expect(response.ip, '8.8.8.8');
    });

    test('coerces a summary whose nested error maps are Map<dynamic, dynamic>',
        () {
      // The platform StandardMessageCodec delivers nested maps as
      // Map<Object?, Object?>; PingError.fromMap (via PingSummary.fromMap)
      // requires Map<String, dynamic>, so the mapper must deep-convert them.
      final Map<dynamic, dynamic> event = <dynamic, dynamic>{
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 5,
        'received': 3,
        'time': 5000000,
        'errors': <dynamic>[
          <dynamic, dynamic>{'error': 'Request Timed Out', 'message': null},
          <dynamic, dynamic>{'error': 'No Reply', 'message': null},
        ],
      };

      final summary = mapNativeEvent(event) as PingSummary;
      expect(summary.transmitted, 5);
      expect(summary.received, 3);
      expect(
        summary.errors.map((e) => e.error).toList(),
        const <ErrorType>[ErrorType.requestTimedOut, ErrorType.noReply],
      );
    });
  });

  // --- NativeEventStatsMapper: the native-result -> event/stats seam ---
  //
  // iOS round-trip statistics are computed by REUSING the core dart_ping
  // RoundTripStatsAccumulator (§spec:stats-ios). These tests assert that the
  // running snapshot on every event and the terminal summary's figures are
  // byte-for-byte the same as the core RoundTripStats.fromSamples over the same
  // per-probe times — including stddev — and that a zero-reply run reports
  // honestly absent figures.
  group('NativeEventStatsMapper (stats parity with core)', () {
    Map<String, dynamic> response(int seq, int timeMicros) => {
          'id': 'run-1',
          'type': 'response',
          'seq': seq,
          'ttl': 64,
          'time': timeMicros,
          'ip': '1.2.3.4',
        };

    test('each probe carries the running snapshot core would compute', () {
      // Sub-millisecond, irregular samples so avg/stddev/jitter are non-trivial.
      const rttsMicros = [1500, 2300, 1100, 4200, 900];
      final mapper = NativeEventStatsMapper();
      final samplesSoFar = <Duration>[];

      for (var i = 0; i < rttsMicros.length; i++) {
        final event = mapper.map(response(i + 1, rttsMicros[i])) as PingResponse;
        samplesSoFar.add(Duration(microseconds: rttsMicros[i]));

        // The i-th event's snapshot equals the core computation over the first
        // i+1 samples — the live↔core parity guarantee (§spec:stats-live).
        expect(event.stats, RoundTripStats.fromSamples(samplesSoFar),
            reason: 'snapshot after sample ${i + 1} must match core');
      }

      // The final running snapshot has a real (non-null) population stddev and
      // jitter — the figures Windows/iOS native output lack — proving iOS gets
      // the full set including stddev (§spec:stats-cross-platform).
      final last = RoundTripStats.fromSamples(samplesSoFar);
      expect(last.stddev, isNotNull);
      expect(last.stddev, isNot(Duration.zero));
      expect(last.jitter, isNotNull);
      expect(last.sampleCount, rttsMicros.length);
    });

    test('an error event carries the snapshot of successful replies so far', () {
      final mapper = NativeEventStatsMapper();
      mapper.map(response(1, 1500));
      mapper.map(response(2, 2500));

      // A timeout does NOT contribute to the RTT figures: its snapshot reflects
      // only the two successful replies seen so far.
      final timeout = mapper.map({
        'id': 'run-1',
        'type': 'error',
        'error': 'Request Timed Out',
        'seq': 3,
      }) as PingError;

      expect(
        timeout.stats,
        RoundTripStats.fromSamples(const [
          Duration(microseconds: 1500),
          Duration(microseconds: 2500),
        ]),
      );
      expect(timeout.stats!.sampleCount, 2);
    });

    test('the terminal summary stats equal core over all per-probe times', () {
      const rttsMicros = [1500, 2300, 1100];
      final mapper = NativeEventStatsMapper();
      for (var i = 0; i < rttsMicros.length; i++) {
        mapper.map(response(i + 1, rttsMicros[i]));
      }

      final summary = mapper.map({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 3,
        'received': 3,
        'time': 9000000,
      }) as PingSummary;

      final expected = RoundTripStats.fromSamples(
        rttsMicros.map((m) => Duration(microseconds: m)),
      );
      expect(summary.stats, expected);
      // received == the successful-sample count the stats summarize.
      expect(summary.received, summary.stats!.sampleCount);
      expect(summary.packetLoss, 0.0);
    });

    test('zero-reply run reports absent figures, 100% loss', () {
      final mapper = NativeEventStatsMapper();
      // Two probes, both errors, no replies.
      mapper.map({
        'id': 'run-1',
        'type': 'error',
        'error': 'Request Timed Out',
        'seq': 1,
      });
      mapper.map({
        'id': 'run-1',
        'type': 'error',
        'error': 'Request Timed Out',
        'seq': 2,
      });

      final summary = mapper.map({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 2,
        'received': 0,
        'time': null,
        'errors': [
          {'error': 'Request Timed Out', 'message': null},
          {'error': 'Request Timed Out', 'message': null},
        ],
      }) as PingSummary;

      // Honest absence: no fabricated zeros for the round-trip figures.
      expect(summary.stats!.sampleCount, 0);
      expect(summary.stats!.min, isNull);
      expect(summary.stats!.avg, isNull);
      expect(summary.stats!.max, isNull);
      expect(summary.stats!.stddev, isNull);
      expect(summary.stats!.jitter, isNull);
      expect(summary.stats, RoundTripStats.fromSamples(const <Duration>[]));
      expect(summary.received, 0);
      expect(summary.packetLoss, 100.0);
    });

    test('a single reply matches core (stddev 0, jitter null)', () {
      final mapper = NativeEventStatsMapper();
      final only = mapper.map(response(1, 1234)) as PingResponse;

      expect(only.stats,
          RoundTripStats.fromSamples(const [Duration(microseconds: 1234)]));
      expect(only.stats!.stddev, Duration.zero);
      expect(only.stats!.jitter, isNull);
    });
  });
}
