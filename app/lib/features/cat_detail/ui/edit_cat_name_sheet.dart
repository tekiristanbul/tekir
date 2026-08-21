import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/states/submitting_button.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/validation/cat_name.dart';
import '../data/cat_detail_api.dart';
import 'cat_detail_notifier.dart';

/// Lets the cat's own owner correct a naming mistake made at creation time
/// (issue #227) — `PATCH /v1/cats/{cat_id}` shipped in #199, but nothing in
/// the app reached it until now. Mirrors [EditDisplayNameSheet]'s own shape
/// verbatim, per product-owner review: pre-filled field, client-side
/// trim/empty validation before the request, a submitting state on the
/// save button, and its exact per-exception error mapping (a distinct
/// message for a network failure, one shared message for everything else —
/// forbidden/not-found/validation/server alike). The caller opens this with
/// `useRootNavigator: true`, exactly like [EditDisplayNameSheet]'s own
/// opener.
class EditCatNameSheet extends ConsumerStatefulWidget {
  const EditCatNameSheet({
    super.key,
    required this.catId,
    required this.currentName,
  });

  final String catId;
  final String currentName;

  @override
  ConsumerState<EditCatNameSheet> createState() => _EditCatNameSheetState();
}

class _EditCatNameSheetState extends ConsumerState<EditCatNameSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentName,
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
    final sanitized = sanitizeCatName(_controller.text);
    if (sanitized == null) {
      setState(() => _errorText = 'Bir isim gir');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    try {
      await ref
          .read(catDetailProvider(widget.catId).notifier)
          .renameCat(sanitized);
      if (mounted) Navigator.of(context).pop(true);
    } on UpdateNetworkException {
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
                  'Kedinin adını düzenle',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.s4),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: InputDecoration(
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
                SubmittingButton(
                  label: 'Kaydet',
                  submittingLabel: 'Kaydediliyor',
                  submitting: _isSubmitting,
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
