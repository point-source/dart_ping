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
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
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
        let ipv6 = (args["ipv6"] as? Bool) ?? false

        let config = PingEngine.Config(
            host: host,
            count: count,
            interval: interval,
            timeout: timeout,
            ttl: ttl,
            ipv6: ipv6
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
        case let .response(seq, ttl, timeMs, ip):
            map = [
                "id": id,
                "type": "response",
                "seq": seq,
                "ttl": ttl,
                "time": timeMs,
                "ip": ip,
            ]
        case let .error(kind, _):
            // `seq` is intentionally not forwarded: the cross-platform
            // PingError model carries no per-error sequence number in this
            // batch and the Dart mapper ignores it. (Re-add to the payload
            // when per-seq error attribution lands.)
            map = [
                "id": id,
                "type": "error",
                "error": Self.message(for: kind),
            ]
        case let .summary(transmitted, received, timeMs):
            map = [
                "id": id,
                "type": "summary",
                "transmitted": transmitted,
                "received": received,
                "time": timeMs,
            ]
            // The summary is terminal for this run.
            stateQueue.async { [weak self] in
                self?.engines.removeValue(forKey: id)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(map)
        }
    }

    /// Human-readable message for each error kind (per the channel contract).
    private static func message(for kind: PingErrorKind) -> String {
        switch kind {
        case .requestTimedOut:
            return "Request Timed Out"
        case .unknownHost:
            return "Unknown Host"
        case .unknown:
            return "Unknown Error"
        }
    }
}
