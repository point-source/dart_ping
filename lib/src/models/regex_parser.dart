import 'dart:async';

import 'package:dart_ping/src/models/ping_data.dart';
import 'package:dart_ping/src/models/ping_error.dart';
import 'package:dart_ping/src/models/ping_response.dart';
import 'package:dart_ping/src/models/ping_summary.dart';

class PingParser {
  PingParser(
      {required this.responseStr,
      required this.responseRgx,
      this.sequenceRgx,
      required this.summaryStr,
      required this.summaryRgx,
      required this.timeoutStr,
      required this.unknownHostStr,
      this.errorStr});

  /// String used to detect a ping response
  RegExp responseStr;

  /// Parses a standard ping response
  /// groups: host, icmp_seq, ttl, time
  RegExp responseRgx;

  /// Parses the sequence identifier
  /// groups: icmp_seq
  RegExp? sequenceRgx;

  /// String used to detect a ping summary
  RegExp summaryStr;

  /// Parses a ping summary
  /// groups: transmitted, received, time (optional)
  RegExp summaryRgx;

  /// String used to detect a timeout error
  RegExp timeoutStr;

  /// String used to detect an unknown host error
  RegExp unknownHostStr;

  /// String(s) used to detect misc unknown error(s)
  RegExp? errorStr;

  StreamTransformer<String, PingData> get responseParser =>
      StreamTransformer<String, PingData>.fromHandlers(
        handleData: (data, sink) {
          // Timeout
          if (sequenceRgx != null && data.contains(timeoutStr)) {
            final match = sequenceRgx!.firstMatch(data);
            if (match == null) {
              return;
            }
            var seq = match.group(1);
            sink.add(
              PingData(
                response: PingResponse(
                  seq: seq == null ? null : int.parse(seq),
                ),
                error: PingError(ErrorType.RequestTimedOut),
              ),
            );
          }

          // Successful response
          if (data.contains(responseStr)) {
            final match = responseRgx.firstMatch(data);
            if (match == null) {
              return;
            }
            var seq = match.group(2);
            var ttl = match.group(3);
            var time = match.group(4);
            sink.add(
              PingData(
                response: PingResponse(
                  ip: match.group(1),
                  seq: seq?.isEmpty ?? true ? null : int.parse(seq!),
                  ttl: ttl == null ? null : int.parse(ttl),
                  time: time == null
                      ? null
                      : Duration(
                          microseconds: ((double.parse(time)) * 1000).floor()),
                ),
              ),
            );
          }

          // Summary
          if (data.contains(summaryStr)) {
            final match = summaryRgx.firstMatch(data);
            var tx = match?.group(1);
            var rx = match?.group(2);
            var time;
            if ((match?.groupCount ?? 0) > 2) {
              time = match?.group(3);
            }
            if (tx == null || rx == null) {
              return;
            }
            sink.add(
              PingData(
                summary: PingSummary(
                  transmitted: int.parse(tx),
                  received: int.parse(rx),
                  time: time == null
                      ? null
                      : Duration(milliseconds: int.parse(time)),
                ),
              ),
            );
          }

          // Unknown Host
          if (data.contains(unknownHostStr)) {
            sink.add(
              PingData(
                error: PingError(ErrorType.UnknownHost),
              ),
            );
          }

          // Other error
          if (errorStr != null && data.contains(errorStr!)) {
            sink.add(
              PingData(
                error: PingError(ErrorType.Unknown, message: data),
              ),
            );
          }
        },
      );
}
