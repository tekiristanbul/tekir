import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/validation/display_name.dart';
import '../../auth/data/auth_api.dart';
import 'profile_notifier.dart';

/// Lets the authenticated account edit its own display name (issue #80
/// product-owner review, finding 2) — the field was previously read-only
/// even though `PATCH /v1/me`/`AuthService.SetDisplayName` already existed
/// and worked. Validation mirrors the server exactly (trim, reject empty,
/// cap at [maxDisplayNameLength]) via the same [sanitizeDisplayName] helper
/// signup's own name step now uses, so the two can never drift apart
/// again.
class EditDisplayNameSheet extends ConsumerStatefulWidget {
  const EditDisplayNameSheet({super.key, required this.currentName});

  final String? currentName;

  @override
  ConsumerState<EditDisplayNameSheet> createState() =>
      _EditDisplayNameSheetState();
}

class _EditDisplayNameSheetState extends ConsumerState<EditDisplayNameSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentName ?? '',
  );
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final sanitized = sanitizeDisplayName(_controller.text);
    if (sanitized == null) {
      setState(() {
        _errorText = _controller.text.trim().isEmpty
            ? 'Bir isim gir'
            : 'İsim en fazla 60 karakter olabilir';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    try {
      await ref.read(profileProvider.notifier).updateDisplayName(sanitized);
      if (mounted) Navigator.of(context).pop(true);
    } on InvalidDisplayNameException {
      setState(() {
        _isSubmitting = false;
        _errorText = 'Bir isim gir';
      });
    } on AuthNetworkException {
      setState(() {
        _isSubmitting = false;
        _errorText = 'Bağlantı sorunu, tekrar dene.';
      });
    } catch (_) {
      setState(() {
        _isSubmitting = false;
        _errorText = 'Sunucuya ulaşılamadı, birazdan tekrar dene.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              AppSpacing.s4,
              AppSpacing.s5,
              AppSpacing.s5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Görünen adını düzenle',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.s4),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  maxLength: maxDisplayNameLength,
                  // cosmetic counter only — a hard client-side truncation
                  // would silently prevent the over-the-cap case from ever
                  // reaching (and exercising) sanitizeDisplayName's own
                  // reject-and-message path below (e.g. on paste).
                  maxLengthEnforcement: MaxLengthEnforcement.none,
                  decoration: InputDecoration(
                    hintText: 'Örn. Ayşe, Mert…',
                    filled: true,
                    fillColor: AppColors.surfaceAlt,
                    contentPadding: const EdgeInsets.all(AppSpacing.s3),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(
                        Radius.circular(AppRadius.md),
                      ),
                      borderSide: BorderSide.none,
                    ),
                    errorText: _errorText,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  height: kTapMin,
                  child: ElevatedButton(
                    onPressed: _isSubmitting ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.primaryInk,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primaryInk,
                            ),
                          )
                        : const Text('Kaydet'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
