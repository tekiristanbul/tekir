/// The reportable surfaces (issue #233): a cat, an update, or a media item
/// (photo/video) — the same closed vocabulary `target_type` accepts on
/// `POST /v1/reports` (docs/architecture/api.md).
enum ReportTargetType {
  cat('cat'),
  update('update'),
  media('media');

  const ReportTargetType(this.wire);

  final String wire;
}

/// The fixed report-reason vocabulary and its turkish label (product-owner
/// decision on issue #233, mirrored by the database's own check
/// constraint — see docs/architecture/db.md). Labels are used verbatim, as
/// specified by the product owner — not restyled or re-punctuated here.
enum ReportReason {
  inappropriate('inappropriate', 'uygunsuz icerik'),
  notACat('not_a_cat', 'kedi degil'),
  wrongInfo('wrong_info', 'yanlis bilgi'),
  spam('spam', 'spam / tekrar eden icerik'),
  privacy('privacy', 'kisisel gizlilik ihlali'),
  other('other', 'diger');

  const ReportReason(this.wire, this.labelTr);

  final String wire;
  final String labelTr;
}

/// The privacy reason's clarifying subtitle (product-owner decision on
/// issue #233) — what counts as a privacy violation in reported media.
/// `null` for every other reason.
String? reportReasonHelperTextTr(ReportReason reason) {
  if (reason == ReportReason.privacy) {
    return 'medyada insan yuzu, ev ici, ozel alan, plaka gibi';
  }
  return null;
}
