/// The UQPAY Flutter SDK — the drop-in payment sheet plus the full headless
/// API.
///
/// ```dart
/// import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';
///
/// final uqpay = UqpaySdk.init(environment: UqpayEnvironment.sandbox);
/// ```
///
/// This library re-exports everything in
/// `package:uqpay_sdk_flutter/headless.dart`, so the sheet's public surface is
/// a strict superset of the headless one by construction — a merchant can
/// always do headlessly whatever the sheet does.
///
/// If you build your own checkout UI, import `headless.dart` instead and avoid
/// the SDK's widgets entirely.
///
/// Nothing under `lib/src/` is public. The two entry-point libraries are the
/// whole API surface.
library;

export 'headless.dart';
export 'src/core/uqpay_clock.dart'
    show SystemUqpayClock, UqpayClock, UqpayDelay;
export 'src/l10n/uqpay_localizations.dart' show UqpayLocalizations;
export 'src/sheet/uqpay_appearance.dart' show UqpayAppearance;
export 'src/sheet/uqpay_payment_sheet.dart' show UqpayPaymentSheet;
export 'src/sheet/uqpay_sheet_presentation.dart'
    show
        UqpayCardOnlyPresentation,
        UqpayMethodListPresentation,
        UqpaySheetPresentation,
        UqpaySingleWalletPresentation;
export 'src/three_ds/uqpay_challenge_page.dart'
    show UqpayChallengePage, UqpayWebviewChallengePresenter;
