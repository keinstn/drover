import Cocoa
import FlutterMacOS
import Speech

class MainFlutterWindow: NSWindow {
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
    speechChannel.setMethodCallHandler { call, result in
      guard call.method == "supportsOnDeviceRecognition" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(SFSpeechRecognizer(locale: Locale.current)?.supportsOnDeviceRecognition ?? false)
    }

    super.awakeFromNib()
  }
}
