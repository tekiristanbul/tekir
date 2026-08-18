import 'package:geolocator/geolocator.dart';

/// The recovery action behind every `konum iznini aç` affordance in the app
/// (issue #262). iOS only ever shows its own permission dialog once per
/// install — after that, [Geolocator.checkPermission] reports
/// `deniedForever` (its mapping for both an explicit prior denial and
/// OS-level `restricted`), and [Geolocator.requestPermission] is a silent
/// no-op against it. `denied` is the one status still worth prompting;
/// everything else can only be reversed from the app's settings page.
///
/// Lives here rather than on one feature's service because the map and
/// discover both offer the same action and must not drift apart on which
/// path they take.
Future<void> recoverLocationPermission() async {
  final permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    await Geolocator.requestPermission();
  } else {
    await Geolocator.openAppSettings();
  }
}
