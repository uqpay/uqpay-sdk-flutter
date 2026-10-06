## 1.0.0-rc.1 - 2026-10-06

First public release candidate of the UQPAY payments SDK for Flutter: a
pure-Dart drop-in payment sheet and a typed headless API for Android, iOS and
web. What the public API promises is described in [STABILITY.md](STABILITY.md).

### Drop-in sheet

- `UqpayPaymentSheet.present(context, payments:, intentId:, returnUrl:)`
  shows a Material 3 bottom sheet and completes with exactly one
  `UqpayPaymentResult` after the sheet closes. The same sheet is an embeddable
  widget whose `onResult` fires exactly once.
- Method list, card form, 3-D Secure step, wallet QR screen and bank-transfer
  instructions.
- Card form with brand detection, Luhn, expiry and CVC checks, and the billing
  fields the gateway requires (state/province only for US, CA, AU, IN, BR and
  MX). Fields validate individually; expiry accepts `12/30`, `12/2030` and
  `1/30`; cardholder names over 128 characters are refused.
- `allowedPaymentMethods` is intersected with the intent's available methods;
  an empty intersection shows a "no payment methods" screen.
- `presentation` (`UqpaySheetPresentation`, sealed): `.methodList()`
  (default), `.cardOnly()` and `.singleWallet(method)`. An invalid combination
  throws `ArgumentError` before any request.
- Back, swipe, tap-outside, the close button and `Navigator.pop` all resolve
  the same way: `Canceled` before a confirm has left the device, `Pending`
  after. The sheet will not close while a confirm is in flight.
- A second `present` for an intent whose sheet is already open returns
  `UqpayPaymentFailed(invalid_configuration)` at once.
- `present` uses the root navigator unless `useRootNavigator: false`.
- Sandbox builds show a test-mode banner on every sheet screen; production
  builds never do.
- Theming follows the host `Theme` (light and dark) with `UqpayAppearance`
  overrides. Every string comes from `UqpayLocalizations` and can be
  overridden. Screen-reader announcements, 48 dp tap targets, and
  left-to-right numeric fields in RTL locales.

### Headless API

- Two entry points: `uqpay_sdk_flutter.dart` (sheet plus headless API) and
  `headless.dart` (typed API, no widgets).
- `UqpaySdk.init` takes `UqpayEnvironment.sandbox` / `.production`, a
  `UqpayTokenProvider`, and optional `clientId`, `onBehalfOf` and
  `baseUrlOverride`. Configuration is validated at `init`.
- `UqpaySdk.payments`: `retrieveIntent`, `confirm`, `createFlow`,
  `awaitOutcome`, `reconcile`, `cancelIntent` and `reconcileUnresolved`. The
  sheet uses only this public API.
- `UqpayPaymentFlow` exposes a `Stream<UqpayPaymentStatus>`, `cancel`,
  `pause`, `resume` and `awaitOutcome` for apps with their own UI.
- `UqpayCardBrand.detect(digits)`. `UqpayCardDetails` fills the
  gateway-required card `network` when you pass `null`, and a missing billing
  first or last name is derived from the cardholder name.
- `UqpayAmount` is an exact decimal parsed from the server's string. The SDK
  never rescales amounts; the currency exponent is used only for formatting.
- Statuses, error codes, cancel reasons and phases are open value types, not
  enums: a new server value parses with `isUnknown == true`.

### Payment flow guarantees

- Every flow delivers exactly one result. Declines, cancellations, timeouts
  and 4xx responses are returned, never thrown; only misconfiguration throws.
- Before confirming, the flow reads the intent; an intent that is already
  `SUCCEEDED` or `REQUIRES_CAPTURE` is reported as paid, not charged again.
- An idempotency key is persisted **before** the confirm leaves the device and
  expires after 24 hours. It depends only on the payment method, so a retry
  after the app is killed reuses it; a definitive server answer releases it, so
  a retry after a decline gets a fresh one.
- A confirm whose outcome is unknown resolves `Pending`, never `Failed`. The
  SDK first replays it (after 3, 6 and 10 seconds) with the same key and an
  identical body, then reads the intent from the server.
- `REQUIRES_PAYMENT_METHOD` counts as a decline only when this confirm's own
  attempt has failed. `REQUIRES_CUSTOMER_ACTION` with a failed attempt and no
  further action resolves `Failed` with the attempt's code.
- `Pending` carries a `reconcile()` helper. `reconcileUnresolved()` resolves
  payments left in flight by a previous process and skips those still being
  paid.
- Polling backs off with jitter and stops on any terminal status. The outcome
  budget (5 minutes for cards, 10 for QR) counts only time that actually
  passed, so app suspension cannot exhaust it.
- `pause()` stops all sending; `resume()` reads the intent once immediately.
  `cancel()` gives `Canceled` before the confirm leaves and `Pending` after.
- Storage calls are bounded at 5 seconds: storage that never answers fails the
  attempt (retryable) before anything is sent.

### 3-D Secure

- An in-app webview page on Android and iOS
  (`UqpayWebviewChallengePresenter`); a full-page redirect on web
  (`UqpayRedirectChallengePresenter`) with `UqpayReturnHandler` to resume on
  return. Supply your own `UqpayChallengePresenter` if you prefer.
- The outcome is always decided by reading the intent from the server, never
  by the return URL.
- The 10-minute challenge window re-arms when the app returns from the
  background. At most three challenges are presented per flow.
- The webview requires `https`, closes only on the return URL, opens
  banking-app, `tel:` and `mailto:` links externally, and clears its cache and
  local storage on exit.
- `UqpayReturnHandler.consume` never throws and ignores a return URL for a
  different intent.

### Wallets and QR

- Merchant-presented QR codes rendered by an in-package encoder, with an
  expiry countdown. A code that expires on screen ends `Pending` with a
  `timeout` cause.
- A hosted QR image is downloaded only over `https` from `uqpay.com` or
  `uqpaytech.com`; otherwise the code is rendered locally.
- The sheet supports `card`, `wechatpay`, `alipaycn`, `alipayhk`, `grabpay`,
  `paynow`, `unionpay`, `truemoney`, `tng`, `gcash`, `dana`, `kakaopay`,
  `tosspay` and `naverpay`. The intent your server creates decides which
  appear.

### Errors and results

- `UqpayPaymentResult` is sealed and frozen for 1.x: `UqpayPaymentCompleted |
  UqpayPaymentFailed | UqpayPaymentCanceled | UqpayPaymentPending`.
- `UqpayError` carries a stable code, developer and user messages,
  `isRetryable`, `isOutcomeUnknown` and the API trace and response ids. See
  [ERROR_CODES.md](ERROR_CODES.md).
- A server code that matches an SDK-reserved code maps to `unknown`, so a
  decline is never mistaken for an unknown outcome.
- Network failures are `network_error`; a malformed response is an unknown
  outcome, not a crash.
- A card confirm with no determinable device IP fails locally with
  `invalid_configuration`; pass `UqpayConfirmRequest.ipAddress`.
- `tokenProvider` calls time out after 30 seconds; a 401 refreshes the token
  once.

### Security and privacy

- No API key in the app: the SDK uses only a short-lived token your backend
  mints. Read the README on what that token can access before going live.
- HTTPS only; `baseUrlOverride` must be a bare `https` origin. On Android and
  iOS the SDK ignores `HttpOverrides.global`.
- Card number, CVC, expiry and cardholder name are never stored. Card numbers
  appear in logs and errors only masked.
- Card fields disable keyboard learning and never save to autofill.
- Diagnostic logging is off by default (`loggingEnabled`, `logHandler`) and
  never logs a body, card data or token.
- No analytics, crash or ad SDKs. See [PRIVACY.md](PRIVACY.md).

### Platforms and requirements

- Android (`minSdk` 24; release builds need the `INTERNET` permission), iOS
  13.0+, and web (JS and Wasm).
- Flutter `>=3.41.0`, Dart `^3.11.0`, UQPAY Payments API v2.
- Pure Dart, no native code. `UqpaySdk.init` throws `UnsupportedError` on
  desktop.

### Example app and reference backend

- `example/`: sheet and headless checkouts, presentation and theming
  switches, startup reconciliation and a webhook viewer.
- `example/backend/`: a Dart `shelf` server that holds the API key, mints the
  client token, creates intents and receives webhooks.

### Known limitations

- Web has no card entry in this version; the sheet offers the intent's other
  methods and says so on screen.
- On web only `redirect_to_url` is supported; `redirect_iframe` fails with
  `invalid_configuration`.
- Browser-based checkout requires UQPAY to enable CORS for your origin. See
  [Web: CORS and origin setup](doc/integration-guide.md#web-cors-and-origin-setup).
- Which wallets are available in sandbox depends on your merchant account.
- No Apple Pay or Google Pay, no native wallet-app hand-off, no desktop.
