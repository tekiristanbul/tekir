/// Turkish, user-friendly distance label for the discover screen's
/// nearby/needs-help lists (issue #82) — "50 m", "1,2 km". Mirrors
/// prototype/data.js's `formatDistance` exactly: under 1km rounds to the
/// nearest 10m (never below 10m, so a cat at the caller's exact position
/// doesn't read as "0 m"), otherwise one decimal km with a turkish comma.
String formatDistanceTr(double meters) {
  if (meters < 1000) {
    final rounded = (meters / 10).round() * 10;
    return '${rounded < 10 ? 10 : rounded} m';
  }
  final km = (meters / 1000).toStringAsFixed(1).replaceAll('.', ',');
  return '$km km';
}
