/// The wallet QR screen and the bank-transfer details screen.
/// Internal — never exported.
library;

import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/src/l10n/l10n_fallbacks.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/qr_encoder.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/qr_matrix.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/uqpay_qr_view.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// Renders the server's QR next action: the raw EMVCo payload is encoded
/// locally and drawn with `UqpayQrView` exactly as sent — never modified —
/// with a visible expiry countdown driven by the injected clock. The screen
/// only ever *waits*; success comes from the server via the flow
/// (a defect seen in an earlier native SDK reported success too early).
class SheetQrScreenView extends StatefulWidget {
  /// Creates the view.
  const SheetQrScreenView({
    required this.l10n,
    required this.qr,
    required this.methodType,
    required this.remaining,
    required this.onCancel,
    super.key,
  });

  /// Hosts a hosted QR image may be downloaded from: the sheet
  /// never contacts anything but UQPAY. A `qr_code_url` elsewhere is ignored
  /// and the raw `qr_code` payload, when present, is rendered locally.
  static const List<String> allowedImageDomains = <String>[
    'uqpay.com',
    'uqpaytech.com',
  ];

  /// Whether [value] is an https URL on an allowed UQPAY host.
  static bool isAllowedImageUrl(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return false;
    }
    final host = uri.host.toLowerCase();
    return allowedImageDomains.any(
      (domain) => host == domain || host.endsWith('.$domain'),
    );
  }

  /// String catalogue.
  final UqpayLocalizations l10n;

  /// The server's QR payload.
  final UqpayDisplayQrCode qr;

  /// The wallet wire type being paid with.
  final String methodType;

  /// Time left until expiry, or `null` when the server sent none.
  final Duration? remaining;

  /// Calls the payment off (yields `Pending` — the confirm has left).
  final VoidCallback onCancel;

  @override
  State<SheetQrScreenView> createState() => _SheetQrScreenViewState();
}

/// The QR countdown text: `m:ss`, or `h:mm:ss` once an hour or more remains.
/// A negative duration shows `0:00`.
String formatQrRemaining(Duration remaining) {
  final total = remaining.inSeconds < 0 ? 0 : remaining.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int n) => n < 10 ? '0$n' : '$n';
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

class _SheetQrScreenViewState extends State<SheetQrScreenView> {
  String? _encodedPayload;
  UqpayQrMatrix? _matrix;

  UqpayQrMatrix? _matrixFor(String payload) {
    // Encoded once per payload, not per countdown tick.
    if (_encodedPayload != payload) {
      _encodedPayload = payload;
      try {
        _matrix = UqpayQrEncoder.encode(payload);
      } on Object {
        // A payload no QR version can hold is server garbage; the screen
        // shows the load-failed text and the flow keeps polling.
        _matrix = null;
      }
    }
    return _matrix;
  }

  static final RegExp _imagePath = RegExp(
    r'\.(png|jpe?g|gif|webp)$',
    caseSensitive: false,
  );

  /// Whether [value] is an allowed https URL whose path names an image file.
  static bool _isHttpsImage(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    return uri != null &&
        SheetQrScreenView.isAllowedImageUrl(value) &&
        _imagePath.hasMatch(uri.path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final theme = Theme.of(context);
    final code = widget.qr.qrCode;
    // With no hosted image, a URL-shaped qr_code is itself the content to
    // scan (`weixin://…`, `https://qr.alipay.com/…`): encode it rather than
    // dead-ending on "could not be displayed" — unless it is an https
    // link to a QR picture, which is shown as one.
    final hostedUrl = widget.qr.qrCodeUrl;
    final imageUrl =
        hostedUrl != null && SheetQrScreenView.isAllowedImageUrl(hostedUrl)
        ? hostedUrl
        : (_isHttpsImage(code) ? code : null);
    final raw = widget.qr.hasRawPayload || imageUrl == null ? code : null;
    final matrix = raw == null ? null : _matrixFor(raw);
    final remaining = widget.remaining;

    Widget qrChild;
    if (matrix != null) {
      qrChild = UqpayQrView(
        matrix: matrix,
        semanticLabel: l10n.qrCodeSemanticLabel,
      );
    } else if (imageUrl != null) {
      qrChild = Semantics(
        label: l10n.qrCodeSemanticLabel,
        image: true,
        child: Image.network(
          imageUrl,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => Center(
            child: Text(
              l10n.qrImageLoadFailed,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : const Center(child: CircularProgressIndicator()),
        ),
      );
    } else {
      qrChild = Center(
        child: Text(
          l10n.qrImageLoadFailed,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.qrInstructionFor(widget.methodType),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          // A fixed square keeps the symbol scannable and cannot overflow a
          // 320 dp column; the QR itself is deliberately unthemed
          // black-on-white for scanner contrast.
          Center(
            child: SizedBox.square(dimension: 220, child: qrChild),
          ),
          const SizedBox(height: 16),
          if (remaining != null)
            // Not a live region: it changes every second, and a screen
            // reader would re-announce every tick for minutes.
            Text(
              l10n.qrExpiresIn(formatQrRemaining(remaining)),
              key: const ValueKey<String>('uqpay-qr-countdown'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: widget.onCancel,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }
}

/// Renders a `display_bank_details` next action.
class SheetBankDetailsView extends StatelessWidget {
  /// Creates the view.
  const SheetBankDetailsView({
    required this.l10n,
    required this.details,
    super.key,
  });

  /// String catalogue.
  final UqpayLocalizations l10n;

  /// The server's transfer details.
  final UqpayDisplayBankDetails details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String?)>[
      (l10n.bankNameLabel, details.bankName),
      (l10n.accountNumberLabel, details.accountNumber),
      (l10n.routingNumberLabel, details.routingNumber),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.bankDetailsTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(l10n.bankDetailsBody, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            if (value != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(value, style: theme.textTheme.bodyLarge),
                  ],
                ),
              ),
          const SizedBox(height: 8),
          const Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ],
      ),
    );
  }
}
