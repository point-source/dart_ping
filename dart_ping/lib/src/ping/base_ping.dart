import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_ping/src/models/ping_data.dart';
import 'package:dart_ping/src/models/ping_error.dart';
import 'package:dart_ping/src/models/ping_summary.dart';
import 'package:dart_ping/src/models/ping_parser.dart';

abstract class BasePing {
  BasePing(
    this.host,
    this.count,
    this.interval,
    this.timeout,
    this.ttl,
    this.ipv6,
    this.parser,
    this.encoding,
    this.forceCodepage,
  ) {
    _controller = StreamController<PingData>(
      onListen: _onListen,
      onCancel: _onCancel,
      onPause: () => _sub.pause,
      onResume: () => _sub.resume,
    );
  }

  /// Hostname, domain, or IP which you would like to ping
  String host;

  /// How many times the host should be pinged before the process ends
  int? count;

  /// Delay between ping attempts
  int interval;

  /// How long to wait for a ping to return before marking it as lost
  int timeout;

  /// How many network hops the packet should travel before expiring
  int ttl;

  /// IPv6 Mode (Not supported on Windows)
  bool ipv6;

  /// Custom parser to interpret ping process output
  /// Useful for non-english based platforms
  PingParser parser;

  /// Encoding used to decode character codes from process output
  Encoding encoding;

  /// On Windows, force the console process to use codepage 437 (DOS Latin US)
  ///
  /// Under the hood, this appends the ping command with the `chcp` command
  /// like so: `chcp 437 && ping {opts}`
  bool forceCodepage;

  late final StreamController<PingData> _controller;
  Process? _process;
  late final StreamSubscription<PingData> _sub;
  PingData? _summaryData;
  final List<PingError> _errors = [];

  /// Command to set english locale before running ping command
  Map<String, String> get locale;

  /// Params and flags that should be applied to the ping command
  List<String> get params;

  /// The command that will be run on the host OS
  String get command => 'ping ${params.join(' ')} $host';

  /// Starts a ping process on the host OS
  Future<Process> get platformProcess async {
    final ping = ipv6 ? 'ping6' : 'ping';

    return await Process.start(
      forceCodepage ? 'chcp' : ping,
      forceCodepage ? ['437', '&&', ping, ...params, host] : [...params, host],
      environment: locale,
      runInShell: forceCodepage,
    );
  }

  /// Transforms the ping process output into PingData objects
  Stream<PingData> get _parsedOutput =>
      StreamGroup.merge([_process!.stderr, _process!.stdout])
          .transform(encoding.decoder)
          .transform(LineSplitter())
          .transform<PingData>(parser.transformParser);

  Future<void> _onListen() async {
    // Start new ping process on host OS
    _process = await platformProcess.catchError((error) {
      if (error.toString().contains('No such file')) {
        throw Exception(
          'Could not find ping binary on this system. Please ensure it is installed',
        );
      }
      throw error;
    });
    // Get platform-specific parsed PingData
    _sub = _parsedOutput.listen(
      (event) {
        if (event.response != null || event.error != null) {
          // Accumulate error if one exists
          if (event.error != null) {
            _errors.add(event.error!);
          }
          _controller.add(event);
        } else if (event.summary != null) {
          event.summary!.errors.addAll(_errors);
          _summaryData = event;
        }
      },
      onDone: _cleanup,
    );
  }

  /// Processes output summary and closes stream after ping process is done
  Future<void> _cleanup() async {
    final exitCode = await _process!.exitCode;

    if (exitCode != 0) {
      // Does the exit code reveal an error?
      final error = interpretExitCode(exitCode);
      if (error != null) {
        // Is there a ping summary that we should add exit code info to?
        if (_summaryData != null) {
          _summaryData!.summary!.errors.add(error);
        } else {
          _summaryData = PingData(
            summary: PingSummary(
              transmitted: 0,
              received: 0,
              time: Duration(),
              errors: [error],
            ),
          );
        }
      } else {
        throwExit(exitCode);
      }
    }

    if (_summaryData != null) {
      _controller.add(_summaryData!);
    }

    // All done! Make sure nothing else gets added
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  /// Interprets exit code into a PingError
  PingError? interpretExitCode(int exitCode);

  /// Converts error exit codes into Exceptions
  Exception? throwExit(int exitCode);

  Stream<PingData> get stream => _controller.stream;

  Future<void> _onCancel() async {
    _process?.kill(ProcessSignal.sigint);
  }

  Future<bool> stop() async {
    if (_process?.kill(ProcessSignal.sigint) ?? false) {
      await _controller.done;

      return true;
    }

    return false;
  }
}
