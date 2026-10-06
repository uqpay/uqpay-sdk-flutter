/// The headless UQPAY API — the typed contract, with no payment UI.
///
/// Import this library when you build your own checkout screens:
///
/// ```dart
/// import 'package:uqpay_sdk_flutter/headless.dart';
/// ```
///
/// This library depends on nothing beyond `flutter` itself and pulls in no
/// widget from the SDK, so it stays cheap for apps that never show the drop-in
/// sheet. Everything the drop-in sheet can do is reachable from here: the sheet
/// is a consumer of this API, not a privileged one.
///
/// For the drop-in payment sheet as well, import
/// `package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart` instead — it exports
/// everything below plus the UI.
///
/// The export list below **is** the public API. It is guarded by
/// `test/public_api_snapshot_test.dart`; every addition or removal is a
/// conscious, reviewed change.
library;

export 'src/errors/uqpay_error.dart' show UqpayError;
export 'src/errors/uqpay_error_code.dart' show UqpayErrorCode;
export 'src/flow/uqpay_cancel_reason.dart' show UqpayCancelReason;
export 'src/flow/uqpay_intent_result.dart'
    show UqpayIntentResult, UqpayIntentRetrieved, UqpayIntentUnavailable;
export 'src/flow/uqpay_payment_flow.dart' show UqpayPaymentFlow;
export 'src/flow/uqpay_payment_result.dart'
    show
        UqpayPaymentCanceled,
        UqpayPaymentCompleted,
        UqpayPaymentFailed,
        UqpayPaymentPending,
        UqpayPaymentResult;
export 'src/flow/uqpay_payment_status.dart'
    show UqpayPaymentPhase, UqpayPaymentStatus;
export 'src/flow/uqpay_payments.dart' show UqpayPayments;
export 'src/models/uqpay_address.dart' show UqpayAddress;
export 'src/models/uqpay_attempt_status.dart' show UqpayAttemptStatus;
export 'src/models/uqpay_authentication_data.dart'
    show UqpayAuthenticationData, UqpayThreeDsResult;
export 'src/models/uqpay_billing_details.dart' show UqpayBillingDetails;
export 'src/models/uqpay_card_brand.dart' show UqpayCardBrand;
export 'src/models/uqpay_confirm_request.dart'
    show
        UqpayBrowserDetails,
        UqpayBrowserInfo,
        UqpayCardDetails,
        UqpayConfirmPaymentMethod,
        UqpayConfirmRequest,
        UqpayLocation,
        UqpayMobileDetails,
        UqpayWalletDetails;
export 'src/models/uqpay_customer.dart' show UqpayCustomer;
export 'src/models/uqpay_intent_status.dart' show UqpayIntentStatus;
export 'src/models/uqpay_json_model.dart' show UqpayJsonModel;
export 'src/models/uqpay_next_action.dart'
    show
        UqpayDisplayBankDetails,
        UqpayDisplayQrCode,
        UqpayNextAction,
        UqpayNextActionType,
        UqpayRedirectIframe,
        UqpayRedirectToUrl;
export 'src/models/uqpay_payment_attempt.dart' show UqpayPaymentAttempt;
export 'src/models/uqpay_payment_intent.dart' show UqpayPaymentIntent;
export 'src/models/uqpay_payment_method.dart'
    show UqpayCardPaymentMethod, UqpayPaymentMethod, UqpayThreeDsData;
export 'src/money/uqpay_amount.dart' show UqpayAmount;
export 'src/three_ds/redirect_challenge_presenter.dart'
    show UqpayRedirectChallengePresenter;
export 'src/three_ds/return_url_matcher.dart' show UqpayReturnUrlMatcher;
export 'src/three_ds/uqpay_challenge_outcome.dart'
    show
        UqpayChallengeDismissed,
        UqpayChallengeFailed,
        UqpayChallengeOutcome,
        UqpayChallengeReturned,
        UqpayChallengeTimedOut;
export 'src/three_ds/uqpay_challenge_presenter.dart'
    show UqpayChallengePresenter, UqpayChallengeRequest;
export 'src/three_ds/uqpay_return_handler.dart' show UqpayReturnHandler;
export 'src/transport/uqpay_token_provider.dart'
    show UqpayAuthToken, UqpayTokenProvider;
export 'src/uqpay_environment.dart' show UqpayEnvironment;
export 'src/uqpay_sdk.dart' show UqpaySdk;
