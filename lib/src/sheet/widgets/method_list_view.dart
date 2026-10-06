/// The payment-method list screen. Internal — never exported.
library;

import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/src/l10n/uqpay_localizations.dart';

/// The method picker: renderable types only, `card` pinned first
/// (server order otherwise), with the web notice when card entry was
/// hidden.
class SheetMethodListView extends StatelessWidget {
  /// Creates the view.
  const SheetMethodListView({
    required this.l10n,
    required this.methods,
    required this.cardHiddenOnWeb,
    required this.onSelect,
    super.key,
  });

  /// String catalogue.
  final UqpayLocalizations l10n;

  /// Wire method types, in display order.
  final List<String> methods;

  /// Whether `card` was hidden because this is a web build.
  final bool cardHiddenOnWeb;

  /// Called with the tapped wire type.
  final ValueChanged<String> onSelect;

  static IconData _iconFor(String type) => switch (type) {
    'card' => Icons.credit_card,
    'paynow' => Icons.qr_code_2,
    _ => Icons.account_balance_wallet_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Text(
            l10n.chooseMethodTitle,
            style: theme.textTheme.titleMedium,
          ),
        ),
        if (cardHiddenOnWeb)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              l10n.webCardUnavailableNotice,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final type in methods)
          Semantics(
            button: true,
            child: ListTile(
              key: ValueKey<String>('uqpay-method-$type'),
              minTileHeight: 56,
              leading: Icon(_iconFor(type)),
              title: Text(l10n.methodDisplayName(type)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onSelect(type),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}
