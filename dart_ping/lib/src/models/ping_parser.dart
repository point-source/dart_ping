import 'dart:async';

import 'package:dart_ping/src/models/ping_data.dart';
import 'package:dart_ping/src/models/ping_error.dart';
import 'package:dart_ping/src/models/ping_response.dart';
import 'package:dart_ping/src/models/ping_summary.dart';

class PingParser {
  PingParser({
    required this.responseRgx,
    required this.summaryRgx,
    required this.timeoutRgx,
    required this.timeToLiveRgx,
    required this.unknownHostStr,
    this.errorStrs = const [],
  });

  /// Parses a standard ping response
  /// groups: host, icmp_seq, ttl, time
  RegExp responseRgx;

  /// Parses a ping summary
  /// groups: transmitted, received, time (optional)
  RegExp summaryRgx;

  /// String used to parse timeout error
  RegExp timeoutRgx;

  /// String used to parse a TTL exceeded error
  RegExp timeToLiveRgx;

  /// String used to detect an unknown host error
  RegExp unknownHostStr;

  /// String(s) used to detect misc unknown error(s)
  List<RegExp> errorStrs;

  // ignore: long-method
  StreamTransformer<String, PingData> get transformParser =>
      StreamTransformer<String, PingData>.fromHandlers(
        handleData: (data, sink) {
          final event = parse(data);
          if (event != null) sink.add(event);
        },
      );

  PingData? parse(String data) {
    RegExpMatch? match;

    // Timeout
    match = timeoutRgx.firstMatch(data);
    if (match != null) {
      var seq =
          match.groupNames.contains('seq') ? match.namedGroup('seq') : null;

      return PingData(
        response: PingResponse(
          seq: seq == null ? null : int.parse(seq),
        ),
        error: PingError(ErrorType.requestTimedOut),
      );
    }

    // Successful response
    match = responseRgx.firstMatch(data);
    if (match != null) {
      var seq =
          match.groupNames.contains('seq') ? match.namedGroup('seq') : null;
      var ttl = match.namedGroup('ttl');
      var time = match.namedGroup('time');

      return PingData(
        response: PingResponse(
          ip: match.namedGroup('ip'),
          seq: seq?.isEmpty ?? true ? null : int.parse(seq!),
          ttl: ttl == null ? null : int.parse(ttl),
          time: time == null
              ? null
              : Duration(
                  microseconds: ((double.parse(time)) * 1000).floor(),
                ),
        ),
      );
    }

    // Summary
    match = summaryRgx.firstMatch(data);
    if (match != null) {
      var tx = match.namedGroup('tx');
      var rx = match.namedGroup('rx');
      String? time;
      if (match.groupCount > 2) {
        time = match.namedGroup('time');
      }
      if (tx == null || rx == null) {
        throw Exception('Error parsing summary data: $data');
      }

      return PingData(
        summary: PingSummary(
          transmitted: int.parse(tx),
          received: int.parse(rx),
          time: time == null ? null : Duration(milliseconds: int.parse(time)),
        ),
      );
    }

    // TTL Exceeded
    match = timeToLiveRgx.firstMatch(data);
    if (match != null) {
      return PingData(
        response: PingResponse(
          ip: match.namedGroup('ip'),
          seq: int.tryParse(match.namedGroup('seq')!),
        ),
        error: PingError(ErrorType.timeToLiveExceeded),
      );
    }

    // Unknown Host
    if (data.contains(unknownHostStr)) {
      return PingData(
        error: PingError(ErrorType.unknownHost),
      );
    }

    // Other error
    for (final regx in errorStrs) {
      final hasMatch = regx.hasMatch(data);
      if (hasMatch) {
        return PingData(
          error: PingError(ErrorType.unknown, message: data),
        );
      }
    }

    return null;
  }
}
