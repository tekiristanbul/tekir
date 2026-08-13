/// Mirrors `CatsService.RenameCat`'s exact validation
/// (backend/internal/service/cats.go): trimmed, non-empty — issue #227.
/// Unlike a display name, a cat name carries no length cap on either side,
/// so this only ever rejects empty/all-whitespace input.
String? sanitizeCatName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}
