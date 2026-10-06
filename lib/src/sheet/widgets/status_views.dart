/// The sheet's async-state screens: loading, load-failed, empty, processing,
/// awaiting and result (every state has a visible affordance).
/// Internal — never exported.
library;

import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/src/l10n/l10n_fallbacks.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// Minimum tap-target side for accessibility.
const double kSheetMinTapTarget = 48;

/// A filled, full-width primary action button with a ≥48 dp tap target.
class SheetPrimaryButton extends StatelessWidget {
  /// Creates the button.
  const SheetPrimaryButton({
    required this.label,
    required this.onPressed,
    this.semanticHint,
    super.key,
  });

  /// The button text.
  final String label;

  /// Tap handler; `null` disables the button.
  final VoidCallback? onPressed;

  /// Optional semantic hint (e.g. why the button is disabled).
  final String? semanticHint;

  @override
  Widget build(BuildContext context) => Semantics(
    hint: semanticHint,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(kSheetMinTapTarget + 4),
      ),
      child: Text(label),
    ),
  );
}

/// A secondary, outlined full-width action button.
class SheetSecondaryButton extends StatelessWidget {
  /// Creates the button.
  const SheetSecondaryButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  /// The button text.
  final String label;

  /// Tap handler; `null` disables the button.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(kSheetMinTapTarget + 4),
    ),
    child: Text(label),
  );
}

/// Shared column layout for status screens: a leading visual, a headline,
/// an optional body and optional actions.
class SheetStatusColumn extends StatelessWidget {
  /// Creates the layout.
  const SheetStatusColumn({
    required this.leading,
    required this.title,
    this.body,
    this.actions = const <Widget>[],
    super.key,
  });

  /// The spinner or icon at the top.
  final Widget leading;

  /// The headline text.
  final String title;

  /// The supporting text, if any.
  final String? body;

  /// Buttons below the text.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: leading),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          if (body != null) ...[
            const SizedBox(height: 8),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          for (final action in actions) ...[
            const SizedBox(height: 16),
            action,
          ],
        ],
      ),
    );
  }
}

/// The loading screen shown while the intent is read.
class SheetLoadingView extends StatelessWidget {
  /// Creates the view.
  const SheetLoadingView({required this.l10n, super.key});

  /// String catalogue.
  final UqpayLocalizations l10n;

  @override
  Widget build(BuildContext context) => SheetStatusColumn(
    leading: const SizedBox.square(
      dimension: 40,
      child: CircularProgressIndicator(),
    ),
    title: l10n.loadingPayment,
  );
}

/// The load-failure screen, with a retry affordance.
class SheetLoadFailedView extends StatelessWidget {
  /// Creates the view.
  const SheetLoadFailedView({
    required this.l10n,
    required this.error,
    required this.onRetry,
    super.key,
  });

  /// String catalogue.
  final UqpayLocalizations l10n;

  /// The mapped failure, when known.
  final UqpayError? error;

  /// Reloads the intent.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SheetStatusColumn(
    leading: Icon(
      Icons.error_outline,
      size: 40,
      color: Theme.of(context).colorScheme.error,
    ),
    title: l10n.loadFailedTitle,
    body: error?.userMessage,
    actions: [SheetPrimaryButton(label: l10n.retry, onPressed: onRetry)],
  );
}

/// The empty-method-list screen. On web with card hidden it shows
/// the documented web limitation instead of a generic emptiness.
class SheetNoMethodsView extends StatelessWidget {
  /// Creates the view.
  const SheetNoMethodsView({
    required this.l10n,
    required this.cardHiddenOnWeb,
    required this.onClose,
    super.key,
  });

  /// String catalogue.
  final UqpayLocalizations l10n;

  /// Whether `card` was offered but hidden because this is a web build.
  final bool cardHiddenOnWeb;

  /// Closes the sheet.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => SheetStatusColumn(
    leading: Icon(
      cardHiddenOnWeb ? Icons.credit_card_off_outlined : Icons.inbox_outlined,
      size: 40,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    title: l10n.noMethodsTitle,
    body: cardHiddenOnWeb ? l10n.webCardOnlyBody : l10n.noMethodsBody,
    actions: [SheetPrimaryButton(label: l10n.closeLabel, onPressed: onClose)],
  );
}

/// The locked-down screen while a confirm is in flight: it tells
/// the customer why the sheet cannot be closed right now.
class SheetProcessingView extends StatelessWidget {
  /// Creates the view.
  const SheetProcessingView({required this.l10n, super.key});

  /// String catalogue.
  final UqpayLocalizations l10n;

  @override
  Widget build(BuildContext context) => SheetStatusColumn(
    leading: const SizedBox.square(
      dimension: 40,
      child: CircularProgressIndicator(),
    ),
    title: l10n.processingTitle,
    body: l10n.processingBody,
  );
}

/// The waiting screen after the confirm was accepted: outcome polling or a
/// verification step in progress. Dismissible — dismissal yields `Pending`.
class SheetAwaitingView extends StatelessWidget {
  /// Creates the view.
  const SheetAwaitingView({
    required this.l10n,
    required this.verifying,
    super.key,
  });

  /// String catalogue.
  final UqpayLocalizations l10n;

  /// Whether a 3-D Secure verification step is running on top of the sheet.
  final bool verifying;

  @override
  Widget build(BuildContext context) => SheetStatusColumn(
    leading: const SizedBox.square(
      dimension: 40,
      child: CircularProgressIndicator(),
    ),
    title: verifying ? l10n.verifyingTitle : l10n.awaitingOutcomeTitle,
    body: verifying ? l10n.verifyingBody : l10n.awaitingOutcomeBody,
  );
}

/// The final result screen: success, pending, failed, cancelled or QR
/// timeout, always with a way out and never a success the server
/// did not confirm.
class SheetResultView extends StatelessWidget {
  /// Creates the view.
  const SheetResultView({
    required this.l10n,
    required this.result,
    required this.qrExpired,
    required this.canTryAgain,
    required this.onTryAgain,
    required this.onClose,
    super.key,
  });

  /// String catalogue.
  final UqpayLocalizations l10n;

  /// The flow's final result.
  final UqpayPaymentResult result;

  /// Whether this result was caused by the QR expiry lapsing.
  final bool qrExpired;

  /// Whether a fresh attempt may be offered.
  final bool canTryAgain;

  /// Starts a fresh attempt.
  final VoidCallback onTryAgain;

  /// Closes the sheet, delivering [result].
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Widget leading, String title, String body) = switch (result) {
      UqpayPaymentCompleted() => (
        Icon(Icons.check_circle_outline, size: 40, color: scheme.primary),
        l10n.successTitle,
        l10n.successBody,
      ),
      UqpayPaymentPending() when qrExpired => (
        Icon(Icons.timer_off_outlined, size: 40, color: scheme.error),
        l10n.qrExpiredTitle,
        l10n.qrExpiredBody,
      ),
      UqpayPaymentPending() => (
        Icon(Icons.hourglass_top_outlined, size: 40, color: scheme.tertiary),
        l10n.pendingTitle,
        l10n.pendingBody,
      ),
      UqpayPaymentFailed(:final error) => (
        Icon(Icons.error_outline, size: 40, color: scheme.error),
        l10n.failedTitle,
        error.userMessage,
      ),
      UqpayPaymentCanceled() => (
        Icon(Icons.cancel_outlined, size: 40, color: scheme.onSurfaceVariant),
        l10n.canceledTitle,
        l10n.canceledBody,
      ),
    };
    return SheetStatusColumn(
      leading: leading,
      title: title,
      body: body,
      actions: [
        if (canTryAgain)
          SheetPrimaryButton(label: l10n.retry, onPressed: onTryAgain),
        if (canTryAgain)
          SheetSecondaryButton(label: l10n.closeLabel, onPressed: onClose)
        else
          SheetPrimaryButton(label: l10n.doneLabel, onPressed: onClose),
      ],
    );
  }
}
