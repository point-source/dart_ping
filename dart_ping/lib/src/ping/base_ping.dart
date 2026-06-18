import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_ping/src/address_family.dart';
import 'package:dart_ping/src/ip_version.dart';
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
    this.ipVersion,
    this.parser,
    this.encoding,
    this.forceCodepage,
  ) {
    // Enforce the literal/family guard on EVERY construction path, not only the
    // `Ping(...)` factory — direct construction of a platform class must fail
    // fast the same way (§spec:address-family-mismatch-validation).
    validateAddressFamily(host, ipVersion);
    _controller = StreamController<PingData>(
      onListen: _onListen,
      onCancel: _onCancel,
      onPause: () => _sub?.pause(),
      onResume: () => _sub?.resume(),
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

  /// The IP address family to ping with — an explicit, exclusive selection
  /// (see [IpVersion]). [IpVersion.ipv6] is not supported on Windows.
  IpVersion ipVersion;

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
  StreamSubscription<PingData>? _sub;
  PingData? _summaryData;
  final List<PingError> _errors = [];

  /// Whether a consumer has begun listening (so [_onListen] has started). Used
  /// by [stop] to decide whether awaiting closure could ever return.
  bool _started = false;

  /// Whether [stop] was requested before the process finished launching, so the
  /// process can be killed as soon as it exists.
  bool _stopRequested = false;

  /// Command to set english locale before running ping command
  Map<String, String> get locale;

  /// Params and flags that should be applied to the ping command
  List<String> get params;

  /// The command that will be run on the host OS
  String get command => 'ping ${params.join(' ')} $host';

  /// The executable used to launch the ping process for the selected
  /// [ipVersion]. The default uses the legacy `ping6` binary for IPv6, which
  /// macOS still relies on. Platforms whose unified `ping` selects the family
  /// by flag instead (Linux/Android pass `-4`/`-6` in [params]) override this
  /// to always use `ping`, so the family is forced explicitly rather than left
  /// to the resolver's default (which can pick the other family on a
  /// dual-stack host).
  String get executable => ipVersion == IpVersion.ipv6 ? 'ping6' : 'ping';

  /// Starts a ping process on the host OS
  Future<Process> get platformProcess async {
    final ping = executable;

    return await Process.start(
      forceCodepage ? 'chcp' : ping,
      forceCodepage ? ['437', '&&', ping, ...params, host] : [...params, host],
      environment: locale,
      runInShell: forceCodepage,
    );
  }

  /// Decodes and line-splits a single raw byte stream so that whole lines are
  /// produced before the streams are merged.
  Stream<String> _lines(Stream<List<int>> raw) =>
      raw.transform(encoding.decoder).transform(const LineSplitter());

  /// Transforms the ping process output into PingData objects
  ///
  /// Each raw stream is decoded and line-split independently before merging, so
  /// interleaved stderr/stdout writes cannot corrupt or split a line.
  Stream<PingData> get _parsedOutput =>
      StreamGroup.merge([_lines(_process!.stderr), _lines(_process!.stdout)])
          .transform<PingData>(parser.transformParser);

  Future<void> _onListen() async {
    _started = true;
    try {
      // Start new ping process on host OS
      _process = await platformProcess;
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
        // Route parser/transform errors through the stream's error channel so
        // they reach the consumer instead of escaping as uncaught async errors;
        // the stream still closes via onDone.
        onError: (Object error, StackTrace stackTrace) {
          if (!_controller.isClosed) {
            _controller.addError(error, stackTrace);
          }
        },
        onDone: _cleanup,
      );
      // A stop() that arrived while the process was still launching could not
      // kill it yet; honor that request now that the process exists.
      if (_stopRequested) {
        _process!.kill(ProcessSignal.sigint);
      }
    } catch (error, stackTrace) {
      // The launch failed before a subscription was established; surface the
      // error and close the stream so the consumer never hangs. If the process
      // had already started before the failure, do not leave it running.
      _process?.kill(ProcessSignal.sigint);
      final mappedError =
          (error is ProcessException && error.errorCode == 2) ||
                  error.toString().contains('No such file')
              ? Exception(
                  'Could not find ping binary on this system. Please ensure it is installed',
                )
              : error;
      _controller.addError(mappedError, stackTrace);
      await _closeController();
    }
  }

  /// Closes the stream controller exactly once.
  Future<void> _closeController() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  /// Processes output summary and closes stream after ping process is done
  ///
  /// The body runs inside a try/finally so the controller closes exactly once
  /// on every terminal path (normal zero-exit, mapped error exit, unmapped
  /// exit, and any unexpected throw), routing failures through the error
  /// channel instead of leaving the consumer to hang.
  Future<void> _cleanup() async {
    try {
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
        } else if (_errors.isEmpty) {
          // Unmapped non-zero exit AND no typed error already surfaced during
          // the run: surface the exception rather than discarding it, so the
          // consumer can catch it. When a typed error did surface (e.g. a
          // `noRoute` line that also makes the process exit non-zero), the
          // consumer already has a catchable signal, so the raw exit Exception
          // would only be a redundant second signal for the same failure.
          final ex = throwExit(exitCode);
          if (ex != null) {
            _controller.addError(ex);
          }
        }
      }

      if (_summaryData != null) {
        _controller.add(_summaryData!);
      }
    } catch (error, stackTrace) {
      // The controller is only closed in the finally below, so it is still
      // open here and the error can always be surfaced.
      _controller.addError(error, stackTrace);
    } finally {
      // All done! Make sure nothing else gets added
      await _closeController();
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
    _stopRequested = true;
    final killed = _process?.kill(ProcessSignal.sigint) ?? false;
    // Await closure whenever a consumer has started listening — even if the
    // process is still launching, since _onListen will kill it once it exists —
    // so stop() never returns before the stream terminates. When nothing was
    // ever started, the controller will never close, so do not await.
    if (_started && !_controller.isClosed) {
      await _controller.done;
    }

    return killed;
  }
}
