import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_outcome.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_presenter.dart';

/// Whether a real challenge webview exists on this platform. This stub —
/// compiled on web/wasm, where `webview_flutter` has no implementation and
/// the SDK uses a redirect instead — reports `false`;
/// `UqpayWebviewChallengePresenter` then fails fast without pushing a page.
bool get isWebviewChallengeSupported => false;

/// Builds the body of `UqpayChallengePage` on platforms without a webview:
/// reports [UqpayChallengeOutcome.failed] once the first frame is up, so a
/// flow waiting on the page is never stuck. Use
/// `UqpayRedirectChallengePresenter` on web instead.
Widget buildChallengeView({
  required UqpayChallengeRequest request,
  required UqpayClock clock,
  required void Function(UqpayChallengeOutcome outcome) onOutcome,
}) => _UnsupportedChallengeView(onOutcome: onOutcome);

/// The UqpayError reported when a webview challenge is requested here.
UqpayError unsupportedWebviewError() => UqpayError(
  code: UqpayErrorCode.invalidConfiguration,
  developerMessage:
      'UqpayChallengePage / UqpayWebviewChallengePresenter need a platform '
      'webview and this platform has none (web builds must use '
      'UqpayRedirectChallengePresenter).',
  userMessage: defaultUserMessage(UqpayErrorCode.invalidConfiguration),
  isRetryable: false,
);

class _UnsupportedChallengeView extends StatefulWidget {
  const _UnsupportedChallengeView({required this.onOutcome});

  final void Function(UqpayChallengeOutcome outcome) onOutcome;

  @override
  State<_UnsupportedChallengeView> createState() =>
      _UnsupportedChallengeViewState();
}

class _UnsupportedChallengeViewState extends State<_UnsupportedChallengeView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onOutcome(
          UqpayChallengeOutcome.failed(unsupportedWebviewError()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'Verification cannot be shown here. Please close this screen '
        'and try again.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
