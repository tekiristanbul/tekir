import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    AppDelegate.configureGoogleMaps()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Google Maps SDK for iOS must be initialized via `GMSServices.provideAPIKey`
  /// before any map view is created, or it terminates the process with an
  /// uncaught `GMSServicesException`. Detect a missing/placeholder key here,
  /// before that happens, and fail with a diagnostic that points at the fix
  /// instead of the native exception.
  private static func configureGoogleMaps() {
    let raw = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String
    let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key, !key.isEmpty, !key.hasPrefix("$("), key != "YOUR_IOS_MAPS_KEY" else {
      fatalError(
        "Google Maps iOS API key is missing. Copy "
          + "app/ios/Flutter/GoogleMaps.xcconfig.example to "
          + "app/ios/Flutter/GoogleMaps.xcconfig and set GOOGLE_MAPS_API_KEY. "
          + "See DEVELOPMENT.md > \"google maps sdk (ios)\"."
      )
    }
    GMSServices.provideAPIKey(key)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
