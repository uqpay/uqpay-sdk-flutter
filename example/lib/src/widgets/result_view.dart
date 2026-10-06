/// Renders a [UqpayPaymentResult] with an exhaustive `switch`.
///
/// `UqpayPaymentResult` is a Dart 3 sealed type with exactly four cases, so
/// the switch below needs no `default` and the compiler fails the build if
/// the SDK ever adds one (it will not — the set is frozen for 1.x).
library;

import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import 'package:uqpay_sdk_flutter_example/src/widgets/common.dart';

/// The four-way result renderer used by both the sheet screen and the
/// headless screen.
class ResultView extends StatelessWidget {
  const ResultView({required this.result, this.onReconcile, super.key});

  /// The result to render.
  final UqpayPaymentResult result;

  /// Called when the tester asks for another server read.
  final void Function(String intentId)? onReconcile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (result) {
      case UqpayPaymentCompleted(:final intent, :final status, :final attempt):
        return _Body(
          key: const Key('result-completed'),
          icon: Icons.check_circle_outline,
          color: scheme.primary,
          headline: 'Completed',
          summary:
              'The customer paid. Your server still fulfils the order from '
              'the webhook, not from this screen.',
          rows: <Widget>[
            LabelledValue(
              label: 'Intent',
              value: intent.id,
              monospace: true,
            ),
            LabelledValue(label: 'Intent status', value: status.raw),
            if (_amountOf(intent) != null)
              LabelledValue(label: 'Amount', value: _amountOf(intent)!),
            if (attempt != null)
              LabelledValue(
                label: 'Attempt status',
                value: attempt.status?.raw ?? '—',
              ),
          ],
        );

      case UqpayPaymentFailed(:final error, :final intentId):
        return _Body(
          key: const Key('result-failed'),
          icon: Icons.error_outline,
          color: scheme.error,
          headline: 'Failed',
          summary: error.userMessage,
          rows: <Widget>[
            LabelledValue(
              label: 'Code',
              value: error.code.raw,
              monospace: true,
            ),
            LabelledValue(
              label: 'Retryable',
              value: error.isRetryable ? 'yes' : 'no',
            ),
            LabelledValue(
              label: 'Outcome unknown',
              value: error.isOutcomeUnknown ? 'yes — reconcile' : 'no',
              valueColor: error.isOutcomeUnknown ? scheme.error : null,
            ),
            LabelledValue(
              label: 'Trace id',
              value: error.traceId ?? '—',
              monospace: true,
            ),
            if (error.httpStatus != null)
              LabelledValue(
                label: 'HTTP status',
                value: '${error.httpStatus}',
              ),
            if (error.serverCode != null)
              LabelledValue(
                label: 'Server code',
                value: error.serverCode!,
                monospace: true,
              ),
            LabelledValue(
              label: 'Developer',
              value: error.developerMessage,
            ),
          ],
          action: error.isOutcomeUnknown
              ? _reconcileButton(intentId, 'Reconcile before retrying')
              : null,
        );

      case UqpayPaymentCanceled(:final reason, :final intentId):
        return _Body(
          key: const Key('result-canceled'),
          icon: Icons.do_not_disturb_on_outlined,
          color: scheme.onSurfaceVariant,
          headline: 'Canceled',
          summary:
              'Nothing was charged. Start a new intent to try again — a '
              'cancelled intent is terminal.',
          rows: <Widget>[
            LabelledValue(
              label: 'Intent',
              value: intentId,
              monospace: true,
            ),
            LabelledValue(label: 'Reason', value: reason.raw),
          ],
        );

      case UqpayPaymentPending(
        :final intentId,
        :final lastKnownStatus,
        :final cause,
      ):
        return _Body(
          key: const Key('result-pending'),
          icon: Icons.hourglass_bottom_outlined,
          color: scheme.tertiary,
          headline: 'Pending',
          summary:
              'The outcome is not known yet. This is NOT a failure — the '
              'payment may still succeed. Do not charge again; reconcile, '
              'or wait for your webhook.',
          rows: <Widget>[
            LabelledValue(
              label: 'Intent',
              value: intentId,
              monospace: true,
            ),
            LabelledValue(
              label: 'Last status',
              value: lastKnownStatus?.raw ?? 'never read',
            ),
            if (cause != null) ...<Widget>[
              LabelledValue(
                label: 'Cause',
                value: cause.code.raw,
                monospace: true,
              ),
              LabelledValue(label: 'Cause detail', value: cause.userMessage),
            ],
          ],
          action: _reconcileButton(intentId, 'Reconcile now'),
        );
    }
  }

  Widget? _reconcileButton(String intentId, String label) {
    final callback = onReconcile;
    if (callback == null) {
      return null;
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonalIcon(
        key: const Key('reconcile-button'),
        onPressed: () => callback(intentId),
        icon: const Icon(Icons.sync),
        label: Text(label),
      ),
    );
  }

  static String? _amountOf(UqpayPaymentIntent intent) {
    final amount = intent.amount;
    final currency = intent.currency;
    if (amount == null || currency == null || currency.isEmpty) {
      return null;
    }
    return '${amount.format(currencyCode: currency)}  '
        '(wire: "${amount.toWireString()}" $currency)';
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.icon,
    required this.color,
    required this.headline,
    required this.summary,
    required this.rows,
    this.action,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String headline;
  final String summary;
  final List<Widget> rows;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Text(
              headline,
              style: theme.textTheme.titleMedium?.copyWith(color: color),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(summary, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 10),
        ...rows,
        if (action != null) ...<Widget>[const SizedBox(height: 12), action!],
      ],
    );
  }
}
