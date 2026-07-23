/// Turkish, user-friendly relative timestamp — "az önce", "12 dakika önce",
/// "3 saat önce", "2 gün önce" — falling back to an absolute `gg.aa.yyyy`
/// date once it's more than a week old. Shared by the map's marker-preview
/// sheet and the cat-detail screen/timeline (docs/design/implementation-
/// contract.md), matching prototype/app.js's `timeText` fixtures in spirit.
String relativeTimeTr(DateTime time, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(time.toLocal());

  if (diff.inSeconds < 60) return 'az önce';
  if (diff.inMinutes < 60) return '${diff.inMinutes} dakika önce';
  if (diff.inHours < 24) return '${diff.inHours} saat önce';
  if (diff.inDays < 7) return '${diff.inDays} gün önce';

  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year}';
}

/// Turkish "time until" for an active needs-help alert's expiry (issue
/// #4/#23) — "1 saat sonra sona eriyor", "45 dakika sonra sona eriyor". Only
/// meaningful for a still-active expiry (expiresAt in the future); an
/// already-past expiresAt isn't formatted here since an expired alert is
/// never shown with active emphasis in the first place.
String expiresInTr(DateTime expiresAt, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = expiresAt.toLocal().difference(reference);

  if (diff.inMinutes < 1) return 'birazdan sona eriyor';
  if (diff.inMinutes < 60) return '${diff.inMinutes} dakika sonra sona eriyor';
  if (diff.inHours < 24) return '${diff.inHours} saat sonra sona eriyor';
  return '${diff.inDays} gün sonra sona eriyor';
}
