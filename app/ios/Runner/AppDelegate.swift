import Flutter
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.keinstn.drover/speech",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "supportsOnDeviceRecognition" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(SFSpeechRecognizer(locale: Locale.current)?.supportsOnDeviceRecognition ?? false)
    }

    let screenChannel = FlutterMethodChannel(
      name: "com.keinstn.drover/screen",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    screenChannel.setMethodCallHandler { call, result in
      guard call.method == "setKeepAwake" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // A malformed/missing argument here is a programming error, not an
      // unimplemented platform method — must not read like the latter, or
      // `runBestEffort` swallows it same as a legitimate no-op while the
      // Dart side has already latched its wake state on.
      guard let args = call.arguments as? [String: Any],
        let enabled = args["enabled"] as? Bool
      else {
        result(FlutterError(code: "bad_args", message: "enabled must be a bool", details: nil))
        return
      }
      // Already on the platform thread: a handler registered without a
      // `taskQueue` runs there, so dispatching again only delays this by a
      // runloop turn for no thread-safety benefit.
      UIApplication.shared.isIdleTimerDisabled = enabled
      result(nil)
    }
  }
}
