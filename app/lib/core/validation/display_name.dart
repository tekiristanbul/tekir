/// Mirrors `AuthService.SetDisplayName`'s exact validation
/// (backend/internal/service/auth.go): trimmed, non-empty, at most this
/// many characters — issue #80 product-owner review, finding 2: signup's
/// own name step used to only check non-empty, silently accepting a name
/// the server would then reject. Both the signup step (auth_notifier.dart)
/// and the later profile edit (edit_display_name_sheet.dart) validate
/// through this single place so they can never drift apart again.
const maxDisplayNameLength = 60;

/// Returns the trimmed, valid display name, or null if [raw] is empty (or
/// all whitespace) after trimming, or exceeds [maxDisplayNameLength].
String? sanitizeDisplayName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > maxDisplayNameLength) return null;
  return trimmed;
}
