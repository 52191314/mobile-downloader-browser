import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let secureChannel = FlutterMethodChannel(
      name: "aurora_downloader/secure_window",
      binaryMessenger: controller.binaryMessenger
    )
    
    secureChannel.setMethodCallHandler { (call, result) in
      if call.method == "enableSecureWindow" {
        DispatchQueue.main.async {
          UIApplication.shared.ignoreSnapshotOnNextApplicationLaunch()
          result(nil)
        }
      } else if call.method == "disableSecureWindow" {
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
