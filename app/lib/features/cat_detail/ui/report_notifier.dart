import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../data/reports_api.dart';
import 'report_reason.dart';

/// Mapped failure for the report sheet to read via
/// [reportSubmitErrorMessageTr] — mirrors [UpdateCorrectionError]'s shape.
enum ReportSubmitError {
  validation,
  noteRequired,
  unauthorized,
  notFound,
  network,
  server,
}

/// Turkish, actionable copy for each mapped failure — short, declarative,
/// no exclamation marks, mirroring [updateCorrectionErrorMessageTr]'s
/// register.
String reportSubmitErrorMessageTr(ReportSubmitError error) {
  return switch (error) {
    ReportSubmitError.validation => 'Bildirim gönderilemedi, tekrar dene.',
    ReportSubmitError.noteRequired => '"Diğer" için kısa bir not ekle.',
    ReportSubmitError.unauthorized => 'Kimlik doğrulanamadı, tekrar dene.',
    ReportSubmitError.notFound => 'Bu içerik artık bulunamıyor.',
    ReportSubmitError.network => 'Bağlantı sorunu, tekrar dene.',
    ReportSubmitError.server => 'Sunucuya ulaşılamadı, birazdan tekrar dene.',
  };
}

class ReportState {
  const ReportState({
    this.reason,
    this.note = '',
    this.isSubmitting = false,
    this.error,
  });

  final ReportReason? reason;
  final String note;
  final bool isSubmitting;
  final ReportSubmitError? error;

  bool get canSubmit => reason != null && !isSubmitting;

  ReportState copyWith({
    ReportReason? reason,
    String? note,
    bool? isSubmitting,
    ReportSubmitError? error,
    bool clearError = false,
  }) {
    return ReportState(
      reason: reason ?? this.reason,
      note: note ?? this.note,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives the report sheet for one specific target (issue #233), one
/// instance per (targetType, targetId) — mirrors [UpdateCorrectionNotifier]'s
/// shape: an in-flight guard, client-side validation before ever calling
/// the api, and a mapped-error state the sheet reads back.
class ReportNotifier extends Notifier<ReportState> {
  ReportNotifier(this.key);

  final ({ReportTargetType targetType, String targetId}) key;

  @override
  ReportState build() => const ReportState();

  void selectReason(ReportReason reason) {
    if (state.isSubmitting) return;
    state = state.copyWith(reason: reason, clearError: true);
  }

  void setNote(String value) {
    state = state.copyWith(note: value, clearError: true);
  }

  Future<bool> submit() async {
    final reason = state.reason;
    if (reason == null || state.isSubmitting) return false;

    final trimmedNote = state.note.trim();
    if (reason == ReportReason.other && trimmedNote.isEmpty) {
      state = state.copyWith(error: ReportSubmitError.noteRequired);
      return false;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      if (ref.read(sessionIdentityServiceProvider).cached == null) {
        state = state.copyWith(
          isSubmitting: false,
          error: ReportSubmitError.unauthorized,
        );
        return false;
      }
      await ref
          .read(reportsApiProvider)
          .submitReport(
            targetType: key.targetType.wire,
            targetId: key.targetId,
            reason: reason.wire,
            note: trimmedNote.isEmpty ? null : trimmedNote,
          );
      state = state.copyWith(isSubmitting: false);
      return true;
    } catch (e) {
      state = state.copyWith(isSubmitting: false, error: _mapError(e));
      return false;
    }
  }

  ReportSubmitError _mapError(Object e) {
    return switch (e) {
      ReportValidationException() => ReportSubmitError.validation,
      ReportUnauthorizedException() => ReportSubmitError.unauthorized,
      ReportTargetNotFoundException() => ReportSubmitError.notFound,
      ReportNetworkException() => ReportSubmitError.network,
      _ => ReportSubmitError.server,
    };
  }
}

final reportProvider =
    NotifierProvider.family<
      ReportNotifier,
      ReportState,
      ({ReportTargetType targetType, String targetId})
    >(ReportNotifier.new);
