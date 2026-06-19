//
//  DartPingIosPlugin.swift
//  dart_ping_ios
//
//  Flutter plugin registrant bridging the Dart channel client to the native
//  Swift `PingEngine` (§spec:spm-distribution). This is the ONLY file in the
//  package that imports Flutter; `PingEngine`/`ICMPPacket` stay Flutter-agnostic.
//
//  Channel contract (must match lib/dart_ping_ios.dart EXACTLY):
//  - MethodChannel `dart_ping_ios`: `start` / `stop`, keyed by a run `id`.
//  - EventChannel `dart_ping_ios/events`: a single shared broadcast stream;
//    every engine event is forwarded to the one sink, tagged with its `id` and
//    a `type`. The terminal `summary` removes the engine from the registry.
//    Event payloads (besides `id`). NOTE: every `time` value is in MICROSECONDS
//    (the Dart `fromMap` decodes `time` as `Duration(microseconds:)`), so
//    sub-millisecond RTT resolution is preserved across the channel:
//      response: `type:"response", seq, ttl, time, ip`
//      error:    `type:"error", error:<message>` (+ `seq` when present, `ip`
//                when the error came from an identified hop, e.g. TTL exceeded)
//      summary:  `type:"summary", transmitted, received, time,
//                 errors:[{error:<message>, message:NSNull}]`
//    `<message>` is one of the exact literals the Dart `ErrorType.fromMessage`
//    matches: "Time To Live Exceeded", "Request Timed Out", "Unknown Host",
//    "No Reply", "No Route", "Unknown Error".
//  - `start` arguments (besides `id`/`host`/`count`/`interval`/`timeout`/`ttl`):
//      ipVersion: a string, the selected address family — "ipv4" or "ipv6"
//                 (the `IpVersion` enum name). Anything other than "ipv6" maps
//                 to IPv4. The engine resolves AND sends for this family only.
//      nat64Synthesis: a bool, default true, gating the NAT64 relaxation. When
//                 true and the selected family is "ipv4" and the host is an IPv4
//                 literal, the engine lets the platform synthesize a NAT64
//                 address so the literal reaches an IPv6-only network; otherwise
//                 it keeps the family-pinned resolve (§spec:nat64-literal-synthesis).
//
//  Threading: `FlutterEventSink` must be invoked on the platform/main thread,
//  but `PingEngine` delivers events on a background queue, so every sink call
//  is marshalled via `DispatchQueue.main.async`.
//

import Flutter
import Foundation

public class DartPingIosPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "dart_ping_ios",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "dart_ping_ios/events",
            binaryMessenger: registrar.messenger()
        )

        let instance = DartPingIosPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - State

    /// The single shared broadcast sink. Stored on `onListen`, cleared on
    /// `onCancel`. Always touched on the main thread.
    private var eventSink: FlutterEventSink?

    /// Events produced before a sink has attached. `start` (MethodChannel) and
    /// the EventChannel `onListen` handshake travel on different channels with
    /// no ordering guarantee, so the engine can emit before the sink registers;
    /// we buffer here and flush on `onListen` rather than dropping them (which
    /// could lose a terminal summary and hang the Dart stream). Main thread only.
    private var pendingEvents: [[String: Any]] = []

    /// Active engines keyed by run `id`. Guarded by `stateQueue` because, while
    /// channel callbacks arrive on the platform thread, summaries that prune the
    /// registry are dispatched from the engine's background queue.
    private var engines: [String: PingEngine] = [:]

    /// Serializes all access to `engines`.
    private let stateQueue = DispatchQueue(label: "com.point-source.dart_ping_ios.plugin.state")

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        // Flush anything that arrived before the sink attached, preserving order.
        if !pendingEvents.isEmpty {
            let buffered = pendingEvents
            pendingEvents.removeAll()
            for map in buffered { events(map) }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        // No listener remains, so any buffered tail belongs to torn-down runs;
        // a future listener is a new run that filters by its own `id`. Drop it
        // so the buffer can't retain stale events for the process lifetime.
        pendingEvents.removeAll()
        return nil
    }

    // MARK: - FlutterPlugin (method calls)

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            handleStart(call.arguments, result: result)
        case "stop":
            handleStop(call.arguments, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - start / stop

    private func handleStart(_ arguments: Any?, result: @escaping FlutterResult) {
        guard
            let args = arguments as? [String: Any],
            let id = args["id"] as? String,
            let host = args["host"] as? String
        else {
            result(nil)
            return
        }

        // `count` is optional (nil => run until stopped). The remaining numeric
        // fields arrive as ints; `interval`/`timeout` are seconds.
        let count = args["count"] as? Int
        let interval = TimeInterval((args["interval"] as? Int) ?? 1)
        let timeout = TimeInterval((args["timeout"] as? Int) ?? 1)
        let ttl = (args["ttl"] as? Int) ?? 255
        // The Dart bridge sends the selected family as the IpVersion enum name
        // ("ipv4" / "ipv6"); default to IPv4 for any absent/unexpected value.
        let ipVersion = (args["ipVersion"] as? String) ?? "ipv4"
        let family: IPFamily = (ipVersion == "ipv6") ? .v6 : .v4
        // Default-on to match the option's default (§spec:nat64-option); the Dart
        // bridge always sends it, but absence/unexpected falls back to enabled.
        let nat64Synthesis = (args["nat64Synthesis"] as? Bool) ?? true

        let config = PingEngine.Config(
            host: host,
            count: count,
            interval: interval,
            timeout: timeout,
            ttl: ttl,
            family: family,
            nat64Synthesis: nat64Synthesis
        )

        let engine = PingEngine(config: config) { [weak self] event in
            self?.forward(event: event, id: id)
        }

        stateQueue.async { [weak self] in
            self?.engines[id] = engine
        }

        engine.start()
        result(nil)
    }

    private func handleStop(_ arguments: Any?, result: @escaping FlutterResult) {
        guard
            let args = arguments as? [String: Any],
            let id = args["id"] as? String
        else {
            result(nil)
            return
        }

        stateQueue.async { [weak self] in
            self?.engines[id]?.stop()
        }

        result(nil)
    }

    // MARK: - Event forwarding

    /// Map a `PingEngine.Event` to the channel Map (tagged with `id` + `type`),
    /// forward it to the shared sink on the main thread, and—on a terminal
    /// summary—remove the engine from the registry.
    private func forward(event: PingEngine.Event, id: String) {
        let map: [String: Any]

        switch event {
        case let .response(seq, ttl, timeMicros, ip):
            var responseMap: [String: Any] = [
                "id": id,
                "type": "response",
                "seq": seq,
                "time": timeMicros,
                "ip": ip,
            ]
            // Include `ttl` only when the reply's hop limit is known. A v6 reply
            // with no IPV6_HOPLIMIT cmsg leaves it nil; omitting the key lets the
            // Dart mapper produce a null ttl rather than a misleading 0.
            if let ttl = ttl { responseMap["ttl"] = ttl }
            map = responseMap
        case let .error(kind, seq, ip):
            var errorMap: [String: Any] = [
                "id": id,
                "type": "error",
                "error": Self.message(for: kind),
            ]
            // Include `seq` when the error is attributable to a probe and `ip`
            // when it came from an identified hop (e.g. TTL exceeded).
            if let seq = seq { errorMap["seq"] = seq }
            if let ip = ip { errorMap["ip"] = ip }
            map = errorMap
        case let .summary(transmitted, received, timeMicros, errors):
            map = [
                "id": id,
                "type": "summary",
                "transmitted": transmitted,
                "received": received,
                "time": timeMicros,
                // Each error becomes {error:<message>, message:null}, matching
                // the cross-platform PingSummary.errors shape.
                "errors": errors.map { kind in
                    ["error": Self.message(for: kind), "message": NSNull()]
                },
            ]
            // The summary is terminal for this run.
            stateQueue.async { [weak self] in
                self?.engines.removeValue(forKey: id)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let sink = self.eventSink {
                sink(map)
            } else {
                // No listener yet: buffer until onListen attaches the sink.
                self.pendingEvents.append(map)
            }
        }
    }

    /// Human-readable message for each error kind (per the channel contract).
    private static func message(for kind: PingErrorKind) -> String {
        switch kind {
        case .requestTimedOut:
            return "Request Timed Out"
        case .timeToLiveExceeded:
            return "Time To Live Exceeded"
        case .noReply:
            return "No Reply"
        case .unknownHost:
            return "Unknown Host"
        case .noRoute:
            return "No Route"
        case .unknown:
            return "Unknown Error"
        }
    }
}
