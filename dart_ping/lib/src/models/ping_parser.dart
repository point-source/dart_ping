import 'dart:async';

import 'package:dart_ping/src/models/ping_event.dart';

class PingParser {
  PingParser({
    required this.responseRgx,
    required this.summaryRgx,
    required this.timeoutRgx,
    required this.timeToLiveRgx,
    required this.unknownHostStr,
    this.noRouteStrs = const [],
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

  /// String(s) used to detect a routing / address-family failure (network unreachable, no route, family unavailable)
  List<RegExp> noRouteStrs;

  /// String(s) used to detect misc unknown error(s)
  List<RegExp> errorStrs;

  StreamTransformer<String, PingEvent> get transformParser =>
      StreamTransformer<String, PingEvent>.fromHandlers(
        handleData: (data, sink) {
          final event = parse(data);
          if (event != null) sink.add(event);
        },
      );

  PingEvent? parse(String data) {
    RegExpMatch? match;

    // Timeout
    match = timeoutRgx.firstMatch(data);
    if (match != null) {
      var seq =
          match.groupNames.contains('seq') ? match.namedGroup('seq') : null;

      return PingError(
        ErrorType.requestTimedOut,
        seq: seq == null ? null : int.parse(seq),
      );
    }

    // Successful response
    match = responseRgx.firstMatch(data);
    if (match != null) {
      var seq =
          match.groupNames.contains('seq') ? match.namedGroup('seq') : null;
      var ttl = match.namedGroup('ttl');
      var time = match.namedGroup('time');

      return PingResponse(
        ip: match.namedGroup('ip'),
        seq: seq?.isEmpty ?? true ? null : int.parse(seq!),
        ttl: ttl == null ? null : int.parse(ttl),
        time: time == null
            ? null
            : Duration(
                microseconds: ((double.parse(time)) * 1000).floor(),
              ),
      );
    }

    // Summary
    match = summaryRgx.firstMatch(data);
    if (match != null) {
      var tx = match.namedGroup('tx');
      var rx = match.namedGroup('rx');
      String? time;
      if (match.groupNames.contains('time')) {
        time = match.namedGroup('time');
      }
      if (tx == null || rx == null) {
        throw Exception('Error parsing summary data: $data');
      }

      // `stats` is left null here; BasePing fills it from per-probe RTTs.
      return PingSummary(
        transmitted: int.parse(tx),
        received: int.parse(rx),
        time: time == null ? null : Duration(milliseconds: int.parse(time)),
      );
    }

    // TTL Exceeded
    match = timeToLiveRgx.firstMatch(data);
    if (match != null) {
      var seq =
          match.groupNames.contains('seq') ? match.namedGroup('seq') : null;

      return PingError(
        ErrorType.timeToLiveExceeded,
        seq: seq == null ? null : int.tryParse(seq),
        ip: match.namedGroup('ip'),
      );
    }

    // Unknown Host
    if (data.contains(unknownHostStr)) {
      return PingError(ErrorType.unknownHost);
    }

    // Routing / address-family failures are classified before the generic
    // `errorStrs` so a recognized "no route for this family" line surfaces the
    // typed `noRoute` rather than the catch-all `unknown`.
    for (final (regexes, type) in [
      (noRouteStrs, ErrorType.noRoute),
      (errorStrs, ErrorType.unknown),
    ]) {
      for (final regx in regexes) {
        if (regx.hasMatch(data)) {
          return PingError(type, message: data);
        }
      }
    }

    return null;
  }
}
