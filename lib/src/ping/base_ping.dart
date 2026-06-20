import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_ping/src/address_family.dart';
import 'package:dart_ping/src/ip_version.dart';
import 'package:dart_ping/src/models/ping_event.dart';
import 'package:dart_ping/src/models/round_trip_stats.dart';
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
    this.interface,
    this.nat64Synthesis,
  ) {
    // Enforce the literal/family guard on EVERY construction path, not only the
    // `Ping(...)` factory — direct construction of a platform class must fail
    // fast the same way (§spec:address-family-mismatch-validation).
    validateAddressFamily(host, ipVersion);
    _controller = StreamController<PingEvent>(
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
  /// (see [IpVersion]).
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

  /// Network interface to originate pings from.
  ///
  /// This single value has a DUAL meaning: it is either an interface *name*
  /// (e.g. `eth0` / `en0`) OR a local source *IP address* (e.g. `192.168.1.5`).
  /// Which form was supplied is classified by [interfaceIsAddress], and each
  /// platform maps it onto the binding flag(s) its `ping` supports. When `null`,
  /// no interface binding is applied.
  String? interface;

  /// Whether an interface selection that should actually be applied was
  /// supplied. An empty string is treated the same as `null` (no selection),
  /// so it never produces a dangling binding flag.
  bool get hasInterface => interface != null && interface!.isNotEmpty;

  /// Whether [interface] holds a source IP address (rather than an interface
  /// name), determined by parsing it as an IP literal via
  /// [InternetAddress.tryParse].
  ///
  /// An IPv6 zone id (e.g. `fe80::1%eth0`) is stripped before parsing because
  /// [InternetAddress.tryParse] rejects the `%zone` suffix; without this a
  /// zone-scoped source address would be misclassified as an interface name.
  bool get interfaceIsAddress =>
      hasInterface &&
      InternetAddress.tryParse(interface!.split('%').first) != null;

  /// Whether the platform may reach an IPv4 literal on an IPv6-only
  /// (NAT64/DNS64) network via the platform's own address synthesis
  /// (§spec:nat64-option).
  ///
  /// Defaults to enabled. It is actively honored ONLY on iOS, where the native
  /// engine can synthesize an IPv6 path to an IPv4 literal. On the subprocess
  /// platforms (Linux/Android, macOS, Windows) it is carried purely for
  /// cross-platform option parity and is an inert NO-OP: it does NOT alter
  /// [params] or [command]. Disabling it restores raw pass-through (the
  /// family-pinned resolve, no synthesis).
  bool nat64Synthesis;

  // Concurrent-isolation invariant (#70): every field below is instance-local
  // mutable state. Each `Ping`/`BasePing` owns its own OS [_process] (and thus
  // its own stdout/stderr pipes), its own [_controller], its own per-call
  // [parser] instance, and its own [_errors]/[_summaryData]/[_rttStats]
  // accumulators. There is no `static`/shared mutable state in this path, so
  // concurrent runs to distinct hosts cannot cross-contaminate. Guarded offline
  // by `test/concurrent_isolation_test.dart`.
  late final StreamController<PingEvent> _controller;
  Process? _process;
  StreamSubscription<PingEvent>? _sub;

  /// Raw parsed summary; its `stats` is null until finalized in [_cleanup].
  PingSummary? _summaryData;
  final List<PingError> _errors = [];

  /// Accumulates per-probe round-trip times so the terminal summary's
  /// [RoundTripStats] is computed from the per-probe replies — the same code on
  /// every subprocess platform (§spec:stats-cross-platform).
  final RoundTripStatsAccumulator _rttStats = RoundTripStatsAccumulator();

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

  /// The executable used to launch the ping process. Every supported core
  /// platform uses the unified `ping` binary: Linux/Android and Windows force
  /// the family with an explicit `-4`/`-6` in [params], while the macOS
  /// subprocess path runs `ping` for IPv4 and rejects IPv6 in [params] before
  /// launch. No platform dispatches to the legacy `ping6` binary. Kept as a
  /// getter so a platform can still override the executable if needed.
  String get executable => 'ping';

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

  /// Transforms the ping process output into [PingEvent] objects
  ///
  /// Each raw stream is decoded and line-split independently before merging, so
  /// interleaved stderr/stdout writes cannot corrupt or split a line.
  Stream<PingEvent> get _parsedOutput => StreamGroup.merge([
    _lines(_process!.stderr),
    _lines(_process!.stdout),
  ]).transform<PingEvent>(parser.transformParser);

  Future<void> _onListen() async {
    _started = true;
    try {
      // Start new ping process on host OS
      _process = await platformProcess;
      // Get platform-specific parsed PingEvents
      _sub = _parsedOutput.listen(
        (event) {
          switch (event) {
            case PingResponse():
              // Successful reply: feed its RTT into the stats accumulator FIRST
              // so the terminal summary's RoundTripStats is built from per-probe
              // times (§spec:stats-cross-platform). Then emit a copy carrying a
              // running snapshot taken AFTER adding this reply's RTT, so the
              // snapshot includes the current reply (§spec:stats-live). Because
              // no successful reply follows the last probe event, that event's
              // snapshot equals the terminal `summary.stats` — the live↔summary
              // consistency guarantee — since both come from the same
              // `_rttStats` accumulator. A consumer derives loss-so-far from
              // `stats.sampleCount` (received-so-far) and the count of probe
              // events it has seen (transmitted-so-far), consistent with the
              // terminal `packetLoss`.
              if (event.time != null) _rttStats.add(event.time!);
              _controller.add(event.copyWith(stats: _rttStats.snapshot()));
            case PingError():
              // Accumulate the BARE error so it is folded into the summary's
              // errors list at cleanup unchanged. Emit a copy carrying the
              // current running snapshot: errors don't contribute to RTT
              // figures, so their snapshot reflects the successful replies seen
              // so far (§spec:stats-live).
              _errors.add(event);
              _controller.add(event.copyWith(stats: _rttStats.snapshot()));
            case PingSummary():
              // Hold the raw parsed summary; it is finalized (stats + errors)
              // in _cleanup.
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

      PingError? exitError;
      if (exitCode != 0) {
        // Does the exit code reveal an error?
        exitError = interpretExitCode(exitCode);
        if (exitError == null) {
          // Unmapped non-zero exit: surface the exception rather than
          // discarding it, so the consumer can catch it. This fires even when
          // a typed error (e.g. a `noRoute` line) already surfaced during the
          // run: the two are independent layers (parsed output vs. process exit
          // code), and suppressing the exit exception whenever any error
          // occurred would also hide a genuinely distinct unmapped exit after
          // unrelated per-probe timeouts, weakening the
          // §spec:stream-lifecycle-robustness guarantee. A noRoute line plus the
          // generic exit exception is a tolerable minor redundancy by contrast.
          final ex = throwExit(exitCode);
          if (ex != null) {
            _controller.addError(ex);
          }
        }
      }

      // Build the terminal summary from the per-probe RTTs (NOT any native
      // stats line), folding in the accumulated errors plus any exit-code
      // error (§spec:stats-cross-platform).
      final errors = [..._errors, ?exitError];
      final stats = _rttStats.snapshot();
      final PingSummary summary;
      if (_summaryData != null) {
        // The native summary line is authoritative for transmitted/received.
        summary = _summaryData!.copyWith(stats: stats, errors: errors);
      } else {
        // No native summary line was parsed (e.g. an unmapped exit, or the
        // process was killed before printing one). Still emit a terminal
        // summary so the run's final event is always a `PingSummary`
        // (§spec:stats-event-model). Reconstruct self-consistent counts from
        // what we actually observed rather than reporting a misleading 0/0:
        // `received` is the number of successful replies (== stats.sampleCount
        // by construction), and `transmitted` adds the probes that failed with
        // a per-probe error (timeout / TTL-exceeded). Run-level errors
        // (noReply / unknownHost / noRoute / unknown) are not probes and do not
        // inflate the count. `time` is left null because the OS-reported
        // wall-clock comes only from the (absent) native summary line.
        final received = stats.sampleCount;
        final probeFailures = _errors
            .where(
              (e) =>
                  e.error == ErrorType.requestTimedOut ||
                  e.error == ErrorType.timeToLiveExceeded,
            )
            .length;
        summary = PingSummary(
          transmitted: received + probeFailures,
          received: received,
          time: null,
          stats: stats,
          errors: errors,
        );
      }

      _controller.add(summary);
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

  Stream<PingEvent> get stream => _controller.stream;

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
