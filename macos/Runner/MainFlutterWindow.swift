import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  let width = 600
  let height = 500

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.styleMask = [
      .nonactivatingPanel,
      .closable,
      .titled,
      .resizable,
    ]
    self.makeKeyAndOrderFront(nil)
    self.isMovableByWindowBackground = false
    self.styleMask.remove(.titled)
    self.level = .mainMenu
    self.isOpaque = false
    self.backgroundColor = NSColor.clear

    // let windowChannel = FlutterMethodChannel(name: "org.spotter-app/window",
    //                                           binaryMessenger: flutterViewController.binaryMessenger)
    // let flutterViewController = FlutterViewController(project: nil, nibName: nil, bundle: nil)
    let windowChannel = FlutterMethodChannel(
      name: "org.spotter-app",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    windowChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: FlutterResult) -> Void in
        if (call.method == "hideWindow") {
          NSApp.hide(nil)
          result(true)
          return
        }

        if (call.method == "showWindow") {
          NSApp.activate(ignoringOtherApps: true)
          result(true)
          return
        }

        result(FlutterMethodNotImplemented)
    })

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
