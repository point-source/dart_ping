import Flutter
import UIKit

public class SwiftDartPingPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let CHANNEL = "dart_ping"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "\(CHANNEL)/method", binaryMessenger: registrar.messenger())
    let stream = FlutterEventChannel(name: "\(CHANNEL)/event", binaryMessenger: registrar.messenger())
    let instance = SwiftDartPingPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    stream.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "stop":
      print("stop")
      GBPingHelper.stop()
    case "start":
      print("start")
      guard let arguments = call.arguments as? [String: Any],
            let host = arguments["host"] as? String else {
        result(FlutterError(code: "Invalid argument", message: nil, details: nil))
        return
      }
      let count = arguments["count"] as? UInt ?? 0
      let interval = arguments["interval"] as? TimeInterval ?? 1
      let ipv6 = arguments["ipv6"] as? Bool ?? false
      GBPingHelper.start(withHost: host, ipv4: !ipv6, ipv6: ipv6, count: count, interval: interval) { ret in
        print(ret)
        if let sink = self.eventSink {
          sink(ret)
        }
      }
      result("started")
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  var eventSink: FlutterEventSink?

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    print(arguments ?? "?")
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    return nil
  }
}
