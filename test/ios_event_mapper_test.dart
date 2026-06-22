import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/ios/ios_event_mapper.dart';
import 'package:test/test.dart';

// Ported from dart_ping_ios/test/ping_event_mapper_test.dart, re-sourced from
// the pure-Dart `NativePingEvent` DTO (decoded from the FFI struct by WS2)
// instead of channel `Map`s.
//
// The channel-codec tests from the source were intentionally DROPPED, because
// they exercise plumbing that no longer exists on the FFI path:
//   * Map<dynamic, dynamic> coercion / nested-error Map coercion — there is no
//     StandardMessageCodec, the DTO is already typed Dart.
//   * native message-string passthrough to PingError.message — the C ABI carries
//     only an error *kind*, so PingError.message is always null here.
//   * unknown-`type` → null — NativeEventKind makes that unrepresentable, so
//     mapNativeEvent is total and never returns null.

void main() {
  // --- mapNativeEvent: pure native-DTO -> bare sealed PingEvent (no stats) ---
  //
  // timeMicros is carried in MICROSECONDS; it is converted with full precision
  // and never rounded to whole milliseconds (§spec:stats-precision).
  group('mapNativeEvent', () {
    test('maps a response event to a PingResponse (microsecond time)', () {
      final event = mapNativeEvent(
        const NativePingEvent(
          kind: .response,
          seq: 3,
          ttl: 55,
          timeMicros: 12000, // microseconds == 12 ms
          ip: '1.2.3.4',
        ),
      );

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
      final response =
          mapNativeEvent(
                const NativePingEvent(
                  kind: .response,
                  seq: 1,
                  timeMicros: 1500,
                  ip: '1.2.3.4',
                ),
              )
              as PingResponse;

      expect(response.time, const Duration(microseconds: 1500));
      expect(response.time!.inMilliseconds, 1); // truncates, but the µs survive
    });

    test('maps a response event missing ttl/ip without throwing', () {
      final response =
          mapNativeEvent(const NativePingEvent(kind: .response, seq: 1))
              as PingResponse;

      expect(response.seq, 1);
      expect(response.ttl, isNull);
      // timeMicros defaults to 0 -> Duration.zero (a response always has a time).
      expect(response.time, Duration.zero);
      expect(response.ip, isNull);
    });

    test('maps a requestTimedOut error to a single PingError carrying seq', () {
      final event = mapNativeEvent(
        const NativePingEvent(
          kind: .error,
          errorKind: .requestTimedOut,
          seq: 4,
        ),
      );

      // The sealed model has no combined response+error: a timed-out probe is
      // ONE PingError that carries its own seq.
      expect(event, isA<PingError>());
      final error = event as PingError;
      expect(error.error, ErrorType.requestTimedOut);
      expect(error.seq, 4);
      expect(error.ip, isNull);
      // No message on the FFI wire.
      expect(error.message, isNull);
    });

    test('maps a timeToLiveExceeded error carrying seq + hop ip', () {
      final error =
          mapNativeEvent(
                const NativePingEvent(
                  kind: .error,
                  errorKind: .timeToLiveExceeded,
                  seq: 7,
                  ip: '10.0.0.1',
                ),
              )
              as PingError;

      expect(error.error, ErrorType.timeToLiveExceeded);
      expect(error.seq, 7);
      expect(error.ip, '10.0.0.1');
    });

    test('a TTL-exceeded error with ip but no seq keeps ip, null seq', () {
      final error =
          mapNativeEvent(
                const NativePingEvent(
                  kind: .error,
                  errorKind: .timeToLiveExceeded,
                  ip: '192.168.1.1',
                ),
              )
              as PingError;

      expect(error.error, ErrorType.timeToLiveExceeded);
      expect(error.ip, '192.168.1.1');
      expect(error.seq, isNull);
    });

    test('maps an unknownHost error with no probe context', () {
      final error =
          mapNativeEvent(
                const NativePingEvent(kind: .error, errorKind: .unknownHost),
              )
              as PingError;

      expect(error.error, ErrorType.unknownHost);
      expect(error.seq, isNull);
      expect(error.ip, isNull);
    });

    test('maps a standalone noReply error', () {
      final error =
          mapNativeEvent(
                const NativePingEvent(kind: .error, errorKind: .noReply),
              )
              as PingError;

      expect(error.error, ErrorType.noReply);
      expect(error.seq, isNull);
    });

    test('maps a standalone noRoute error, distinct from unknownHost', () {
      // The native engine reports noRoute when resolution/send for the SELECTED
      // family is impossible. It must land as ErrorType.noRoute, distinct from
      // unknownHost.
      final error =
          mapNativeEvent(
                const NativePingEvent(kind: .error, errorKind: .noRoute),
              )
              as PingError;

      expect(error.error, ErrorType.noRoute);
      expect(error.error, isNot(ErrorType.unknownHost));
    });

    test('maps an unknown error via the catch-all', () {
      final error =
          mapNativeEvent(
                const NativePingEvent(kind: .error, errorKind: .unknown),
              )
              as PingError;

      expect(error.error, ErrorType.unknown);
    });

    test('maps a summary event WITH a time (microseconds)', () {
      final event = mapNativeEvent(
        const NativePingEvent(
          kind: .summary,
          transmitted: 5,
          received: 4,
          timeMicros: 5000000, // microseconds == 5 s
        ),
      );

      expect(event, isA<PingSummary>());
      final summary = event as PingSummary;
      expect(summary.transmitted, 5);
      expect(summary.received, 4);
      expect(summary.time, const Duration(seconds: 5));
      expect(summary.errors, isEmpty);
    });

    test('maps a summary event WITHOUT a time (timeMicros 0 -> null)', () {
      final summary =
          mapNativeEvent(
                const NativePingEvent(
                  kind: .summary,
                  transmitted: 2,
                  received: 0,
                  // timeMicros defaults to 0 -> null time.
                ),
              )
              as PingSummary;

      expect(summary.transmitted, 2);
      expect(summary.received, 0);
      expect(summary.time, isNull);
      expect(summary.errors, isEmpty);
    });

    test('maps a summary carrying a mix of errors, in order', () {
      final summary =
          mapNativeEvent(
                const NativePingEvent(
                  kind: .summary,
                  transmitted: 5,
                  received: 0,
                  timeMicros: 5000000,
                  errors: [
                    .timeToLiveExceeded,
                    .requestTimedOut,
                    .unknownHost,
                    .noReply,
                    .unknown,
                  ],
                ),
              )
              as PingSummary;

      expect(summary.errors.map((e) => e.error).toList(), const <ErrorType>[
        ErrorType.timeToLiveExceeded,
        ErrorType.requestTimedOut,
        ErrorType.unknownHost,
        ErrorType.noReply,
        ErrorType.unknown,
      ]);
    });

    test('maps a summary with an explicitly empty errors list to []', () {
      final summary =
          mapNativeEvent(
                const NativePingEvent(
                  kind: .summary,
                  transmitted: 3,
                  received: 3,
                  timeMicros: 3000000,
                  errors: [],
                ),
              )
              as PingSummary;

      expect(summary.errors, isEmpty);
    });
  });

  // --- §spec:nat64-error-fallback: the synthesis-failure honest-error fallback
  //     at the Dart mapping seam --------------------------------------------
  //
  // When the native engine attempts NAT64 synthesis for an IPv4 literal and the
  // platform yields no routable address, it emits the honest noRoute kind. These
  // tests pin that the Dart mapper turns that into the honest typed PingError —
  // NOT a phantom unknownHost — and that a genuine name miss stays unknownHost.
  group('NAT64 synthesis-failure fallback maps to the honest typed error', () {
    test(
      'a noRoute synthesis failure maps to ErrorType.noRoute, not a phantom',
      () {
        final event = mapNativeEvent(
          const NativePingEvent(kind: .error, errorKind: .noRoute),
        );

        expect(event, isA<PingError>());
        expect((event as PingError).error, ErrorType.noRoute);
        expect(event.error, isNot(ErrorType.unknownHost)); // not a phantom
      },
    );

    test('a genuine unknownHost stays ErrorType.unknownHost', () {
      final event = mapNativeEvent(
        const NativePingEvent(kind: .error, errorKind: .unknownHost),
      );

      expect((event as PingError).error, ErrorType.unknownHost);
    });
  });

  group(
    'NAT64 regression guards: synthesis must not disturb working paths',
    () {
      test(
        'a normal response still maps to an intact PingResponse + stats',
        () {
          final mapper = NativeEventStatsMapper();
          final response =
              mapper.map(
                    const NativePingEvent(
                      kind: .response,
                      seq: 2,
                      ttl: 64,
                      timeMicros: 12000, // microseconds == 12 ms
                      ip: '13.35.27.1',
                    ),
                  )
                  as PingResponse;

          expect(response.seq, 2);
          expect(response.ttl, 64);
          expect(response.time, const Duration(microseconds: 12000));
          expect(response.ip, '13.35.27.1');
          // The working live path still stamps the running snapshot.
          expect(response.stats, isNotNull);
          expect(response.stats!.sampleCount, 1);
        },
      );

      test('the bare mapper still maps a normal response unchanged', () {
        final response =
            mapNativeEvent(
                  const NativePingEvent(
                    kind: .response,
                    seq: 5,
                    ttl: 55,
                    timeMicros: 9000,
                    ip: '1.1.1.1',
                  ),
                )
                as PingResponse;

        expect(response.seq, 5);
        expect(response.ttl, 55);
        expect(response.time, const Duration(microseconds: 9000));
        expect(response.ip, '1.1.1.1');
        expect(response.stats, isNull); // bare mapper attaches no stats
      });
    },
  );

  // --- NativeEventStatsMapper: the native-event -> event/stats seam ---
  //
  // iOS round-trip statistics are computed by REUSING the core dart_ping
  // RoundTripStatsAccumulator (§spec:stats-ios). These tests assert that the
  // running snapshot on every event and the terminal summary's figures are
  // byte-for-byte the same as the core RoundTripStats.fromSamples over the same
  // per-probe times — including stddev — and that a zero-reply run reports
  // honestly absent figures.
  group('NativeEventStatsMapper (stats parity with core)', () {
    NativePingEvent response(int seq, int timeMicros) => .new(
      kind: .response,
      seq: seq,
      ttl: 64,
      timeMicros: timeMicros,
      ip: '1.2.3.4',
    );

    test('each probe carries the running snapshot core would compute', () {
      // Sub-millisecond, irregular samples so avg/stddev/jitter are non-trivial.
      const rttsMicros = [1500, 2300, 1100, 4200, 900];
      final mapper = NativeEventStatsMapper();
      final samplesSoFar = <Duration>[];

      for (int i = 0; i < rttsMicros.length; i += 1) {
        final event =
            mapper.map(response(i + 1, rttsMicros[i])) as PingResponse;
        samplesSoFar.add(Duration(microseconds: rttsMicros[i]));

        // The i-th event's snapshot equals the core computation over the first
        // i+1 samples — the live↔core parity guarantee (§spec:stats-live).
        expect(
          event.stats,
          RoundTripStats.fromSamples(samplesSoFar),
          reason: 'snapshot after sample ${i + 1} must match core',
        );
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
      final timeout =
          mapper.map(
                const NativePingEvent(
                  kind: .error,
                  errorKind: .requestTimedOut,
                  seq: 3,
                ),
              )
              as PingError;

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
      for (int i = 0; i < rttsMicros.length; i += 1) {
        mapper.map(response(i + 1, rttsMicros[i]));
      }

      final summary =
          mapper.map(
                const NativePingEvent(
                  kind: .summary,
                  transmitted: 3,
                  received: 3,
                  timeMicros: 9000000,
                ),
              )
              as PingSummary;

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
      mapper.map(
        const NativePingEvent(
          kind: .error,
          errorKind: .requestTimedOut,
          seq: 1,
        ),
      );
      mapper.map(
        const NativePingEvent(
          kind: .error,
          errorKind: .requestTimedOut,
          seq: 2,
        ),
      );

      final summary =
          mapper.map(
                const NativePingEvent(
                  kind: .summary,
                  transmitted: 2,
                  received: 0,
                  // timeMicros 0 -> null time.
                  errors: [.requestTimedOut, .requestTimedOut],
                ),
              )
              as PingSummary;

      // Honest absence: no fabricated zeros for the round-trip figures.
      expect(summary.stats!.sampleCount, 0);
      expect(summary.stats!.min, isNull);
      expect(summary.stats!.avg, isNull);
      expect(summary.stats!.max, isNull);
      expect(summary.stats!.stddev, isNull);
      expect(summary.stats!.jitter, isNull);
      expect(summary.stats, RoundTripStats.fromSamples(const []));
      expect(summary.received, 0);
      expect(summary.packetLoss, 100.0);
    });

    test('a single reply matches core (stddev 0, jitter null)', () {
      final mapper = NativeEventStatsMapper();
      final only = mapper.map(response(1, 1234)) as PingResponse;

      expect(
        only.stats,
        RoundTripStats.fromSamples(const [Duration(microseconds: 1234)]),
      );
      expect(only.stats!.stddev, Duration.zero);
      expect(only.stats!.jitter, isNull);
    });
  });
}
