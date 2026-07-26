import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Keeps a map camera within greater istanbul so it can't be panned out to
/// a city/country view — the product wants a street-level experience, not
/// a general-purpose map (docs/product/map.md). Shared by the main map
/// screen and the add-cat location picker (issue #70) so both enforce the
/// exact same boundary — this is also the one definition
/// `CatsService.Create`'s server-side area validation mirrors (see
/// backend/internal/service/cats.go's `istanbulBounds`).
final istanbulBounds = LatLngBounds(
  southwest: const LatLng(40.80, 28.35),
  northeast: const LatLng(41.40, 29.55),
);
const istanbulMinZoom = 12.0;
const istanbulMaxZoom = 20.0;
