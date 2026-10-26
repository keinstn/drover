import AVFoundation
import Cocoa
import FlutterMacOS
import Speech

class MainFlutterWindow: NSWindow {
  private let speaker = DroverSpeaker()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let speechRegistrar = flutterViewController.registrar(
      forPlugin: "DroverSpeechCapabilities"
    )
    let speechChannel = FlutterMethodChannel(
      name: "com.keinstn.drover/speech",
      binaryMessenger: speechRegistrar.messenger
    )
    speechChannel.setMethodCallHandler { [speaker] call, result in
      guard call.method == "supportsOnDeviceRecognition" else {
        speaker.handle(call, result: result)
        return
      }
      result(SFSpeechRecognizer(locale: Locale.current)?.supportsOnDeviceRecognition ?? false)
    }

    super.awakeFromNib()
  }
}

/// Speaks conversation-mode replies. One synthesizer lives for the app's
/// lifetime; each `speak` call's result is answered when its utterance
/// finishes or is cancelled, so Dart can await the end of speech.
// @unchecked: the delegate protocol is Sendable, but all state is only
// touched on the main thread (channel calls arrive there and the delegate
// callbacks hop to it).
final class DroverSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  private let synthesizer = AVSpeechSynthesizer()
  private var pending: (utterance: AVSpeechUtterance, result: FlutterResult)?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "speak":
      guard let args = call.arguments as? [String: Any],
        let text = args["text"] as? String,
        let locale = args["locale"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "speak needs text and locale", details: nil))
        return
      }
      speak(text, locale: locale, result: result)
    case "stopSpeaking":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func speak(_ text: String, locale: String, result: @escaping FlutterResult) {
    stop()
    let utterance = AVSpeechUtterance(string: text)
    // rawValue orders default < enhanced < premium without needing the
    // availability check `.premium` would.
    utterance.voice =
      AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.caseInsensitiveCompare(locale) == .orderedSame }
      .max { $0.quality.rawValue < $1.quality.rawValue }
      ?? AVSpeechSynthesisVoice(language: locale)
    pending = (utterance, result)
    synthesizer.speak(utterance)
  }

  /// Answers the pending result right away; the late didCancel for its
  /// utterance is then ignored because it no longer matches `pending`.
  private func stop() {
    complete(pending?.utterance)
    if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
  }

  private func complete(_ utterance: AVSpeechUtterance?) {
    guard let current = pending, current.utterance === utterance else { return }
    pending = nil
    current.result(nil)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    DispatchQueue.main.async { self.complete(utterance) }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    DispatchQueue.main.async { self.complete(utterance) }
  }
}
