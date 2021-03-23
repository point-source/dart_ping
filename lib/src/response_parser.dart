import 'dart:async';

import 'models/ping_data.dart';
import 'models/ping_error.dart';
import 'models/ping_response.dart';
import 'models/ping_summary.dart';

StreamTransformer<String, PingData> responseParser(
        {required RegExp responseRgx,
        RegExp? sequenceRgx,
        required RegExp summaryRgx,
        required RegExp responseStr,
        required RegExp summaryStr,
        required RegExp timeoutStr,
        required RegExp unknownHostStr,
        RegExp? errorStr}) =>
    StreamTransformer<String, PingData>.fromHandlers(
      handleData: (data, sink) {
        // Timeout
        if (sequenceRgx != null && data.contains(timeoutStr)) {
          final match = sequenceRgx.firstMatch(data);
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
                seq: seq == null ? null : int.parse(seq),
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
          var time = match?.group(3);
          if (tx == null || rx == null || time == null) {
            return;
          }
          sink.add(
            PingData(
              summary: PingSummary(
                transmitted: int.parse(tx),
                received: int.parse(rx),
                time: Duration(milliseconds: int.parse(time)),
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
        if (errorStr != null && data.contains(errorStr)) {
          sink.add(
            PingData(
              error: PingError(ErrorType.Unknown, message: data),
            ),
          );
        }
      },
    );
