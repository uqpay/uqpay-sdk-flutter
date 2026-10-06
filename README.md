# uqpay_sdk_flutter

Accept card, wallet and QR payments in your Flutter app with UQPAY. A pure-Dart
drop-in payment sheet plus a typed headless API for Android, iOS and web.

> **Status: release candidate `1.0.0-rc.1`.** The public API on this page is
> the 1.0.0 contract: the result types are sealed and frozen for 1.x, and the
> exported symbol list is pinned by a golden test. The SDK is tested against
> the UQPAY **sandbox** on an iOS simulator and an Android emulator. Platform floors can still move before 1.0.0 (see
> [STABILITY.md](STABILITY.md)). Integrate and test in sandbox, and read
> [Limitations](#limitations) and the
> [security checklist](#security-checklist-for-production) before you take
> real payments.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [How it works](#how-it-works)
- [Quickstart](#quickstart) — [startup](#startup)
- [Handling the result](#handling-the-result) — [pending](#pending-and-reconciliation) · [errors](#errors)
- [Configuration](#configuration) — [`init`](#uqpaysdkinit) · [`present`](#uqpaypaymentsheetpresent) · [presentation](#presentation-and-allowed-methods) · [test-mode banner](#test-mode-banner) · [appearance](#appearance) · [localizations](#localizations)
- [3-D Secure and return URLs](#3-d-secure-and-return-urls)
- [Headless API](#headless-api)
- [Sandbox testing](#sandbox-testing)
- [Security](#security) — [checklist for production](#security-checklist-for-production)
- [Limitations](#limitations)
- [Compatibility](#compatibility)
- [Documentation](#documentation) · [Support](#support) · [License](#license)

---

## Features

- **Drop-in payment sheet.** One call — `UqpayPaymentSheet.present(...)` —
  shows a Material 3 bottom sheet with the method list, the card form, the
  3-D Secure step and the wallet QR screen, and returns one typed result. The
  same widget is embeddable in your own page.
- **Headless API.** Everything the sheet does is a public `UqpayPayments`
  call: `retrieveIntent`, `confirm`, `createFlow`, `awaitOutcome`,
  `reconcile`, `cancelIntent`, `reconcileUnresolved`. The sheet is a consumer
  of this API, not a privileged one; an import-boundary test enforces it.
- **Cards with 3-D Secure** on Android and iOS. The challenge runs in an
  in-app webview. Card brand detection (`UqpayCardBrand`) fills the
  gateway-required `network` field for you. Web has no card entry in this
  version; redirect-based methods use a full-page redirect there.
- **Wallets and QR.** Merchant-presented QR codes and bank-transfer
  instructions in-sheet, with an expiry countdown. The sheet renders `card`,
  `wechatpay`, `alipaycn`, `alipayhk`, `grabpay`, `paynow`, `unionpay`,
  `truemoney`, `tng`, `gcash`, `dana`, `kakaopay`, `tosspay` and `naverpay`;
  which of those appear is decided by the intent your server created.
- **One sealed result.** `UqpayPaymentResult` is
  `Completed | Failed | Canceled | Pending`, frozen for 1.x, so your `switch`
  is exhaustive and a new SDK version cannot add a case you forgot.
- **Honest about unknown outcomes.** A payment the device cannot settle
  resolves `Pending` with a `reconcile()` helper, never a false failure. An
  idempotency key is persisted *before* the confirm leaves the device, and
  `reconcileUnresolved()` resolves payments interrupted by process death.
- **No API key in the app.** The SDK authenticates only with a short-lived
  token your backend mints; there is no parameter that accepts an API key.
  Read [what that token can do](#what-the-auth-token-can-do) before you go
  live.
- **Pure Dart.** No first-party native code, no platform channels, no
  analytics, crash or ad SDK. Network calls go only to the configured UQPAY
  environment (plus, for some wallets, a QR image on an `https` UQPAY
  domain).

## Requirements

- Flutter `>=3.41.0` / Dart `^3.11.0` (see [Compatibility](#compatibility)).
- Android (`minSdk` 24), iOS 13.0+ or web. Desktop is not supported:
  `UqpaySdk.init` throws an `UnsupportedError` naming the platform.
- A UQPAY merchant account with **sandbox** credentials (client id and API
  key) for your **server**. The app never sees them.
- A backend endpoint that mints the client token and one that creates the
  payment intent — see [How it works](#how-it-works) and the
  [integration guide](doc/integration-guide.md).

## Installation

```sh
flutter pub add uqpay_sdk_flutter
```

Until 1.0.0 ships only release candidates exist. A caret range such as
`^1.0.0-rc.1` (what `flutter pub add` writes) also accepts later release
candidates (`1.0.0-rc.2`, …), which may still move platform floors. Pin the
exact version in `pubspec.yaml` and move off it deliberately:

```yaml
dependencies:
  uqpay_sdk_flutter: 1.0.0-rc.1
```

Then import one of the two entry points:

```dart
// Drop-in payment sheet + the full headless API.
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

// Headless API only — no widgets — if you build your own checkout UI.
import 'package:uqpay_sdk_flutter/headless.dart';
```

The package ships no native code of its own; the 3-D Secure webview, local
storage and the web redirect come from `webview_flutter`,
`shared_preferences` and `url_launcher`, which the Flutter tool links for
you. Platform setup is one line on Android and nothing elsewhere:

- **Android: add the `INTERNET` permission for release builds.** Flutter's
  Android app template declares it only in
  `android/app/src/debug/AndroidManifest.xml` and
  `android/app/src/profile/AndroidManifest.xml`, so debug and profile builds
  work and a release build fails every request. A pure-Dart package such as
  this one has no Android manifest of its own and cannot add the permission
  for you, and none of its dependencies (`webview_flutter_android`,
  `shared_preferences_android`, `url_launcher_android`) declare it. Add it to
  the **main** manifest, `android/app/src/main/AndroidManifest.xml`:

  ```xml
  <manifest xmlns:android="http://schemas.android.com/apk/res/android">
      <uses-permission android:name="android.permission.INTERNET"/>
      <!-- your existing <application> element -->
  </manifest>
  ```

- **Android `minSdk` 24 and iOS 13.0** are the defaults of a new Flutter 3.41
  app; nothing to change unless you lowered them.
- **No URL scheme or intent filter.** No `Info.plist` URL scheme and no
  Android intent filter are needed for the 3-D Secure return URL — see
  [3-D Secure and return URLs](#3-d-secure-and-return-urls).
- **Web** needs no `index.html` changes.

## How it works

Your server holds the UQPAY API key; the app never does.

```
┌──────────┐ 1. "pay for order 42"  ┌──────────────┐  x-api-key   ┌───────┐
│ Your app │ ─────────────────────▶ │ Your backend │ ───────────▶ │ UQPAY │
│          │ ◀───────────────────── │              │ ◀─────────── │  API  │
│          │ 2. intent id           └──────────────┘              └───────┘
│          │    + client token             ▲  4. retrieve the intent,  ▲
│  sheet   │                               │     then fulfil           │
│          │ 3. card form, 3DS, QR, polling — straight to UQPAY ───────┘
└──────────┘
```

1. **Your server creates the payment intent** from its own order record and
   **mints a short-lived auth token** with its API key
   (`POST /api/v1/connect/token`). UQPAY allows **one active token per
   merchant** — minting a new one invalidates the previous one — so the mint
   must be cached and single-flighted in exactly one place on your server,
   never per device.
2. **The app calls `UqpaySdk.init`** with a `tokenProvider` that fetches that
   token from your server, then **`UqpayPaymentSheet.present`** with the
   intent id.
3. **The sheet takes the payment** and returns a result — a UX signal for the
   customer.
4. **Your server confirms** by retrieving the intent from the UQPAY API before
   it ships anything. A webhook is a prompt to do that, not proof on its own.

[`example/backend/`](example/backend/) is a working reference backend with
tests, and [`example/`](example/) a runnable app on Android, iOS and web.

## Quickstart

**What the quickstart assumes.** The checkout below uses a Flutter import,
your own backend client and four UI helpers of yours. Their shapes are:

~~~dart
import 'package:flutter/material.dart';

/// Your own client for YOUR backend — not UQPAY's API.
abstract class MyBackend {
  /// The JSON body of your "give me a UQPAY token" endpoint:
  /// {"auth_token": "...", "expired_at": <epoch seconds>}
  Future<Map<String, Object?>> fetchUqpayToken();

  /// Creates the payment intent on your server and returns its id.
  Future<String> createPaymentIntent({
    required String amount,
    required String currency,
    required Uri returnUrl,
  });
}

// Your UI.
void showThankYou() {}
void showError(String message, {required bool retryable}) {}
void showCancelled() {}
void showPending(String intentId) {}
~~~

**The checkout.** Copy this into your checkout page. It is **compiled in
CI** — a test asserts this block is byte-identical to real code in the
repository, so it cannot drift from an API that still works.

```dart
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

Future<void> checkout(BuildContext context, MyBackend myBackend) async {
  // 1. Point the SDK at an environment. It never holds an API key — your
  //    backend mints a short-lived token and the SDK refreshes it via this
  //    callback.
  final uqpay = UqpaySdk.init(
    environment: UqpayEnvironment.sandbox,
    tokenProvider: () async =>
        UqpayAuthToken.fromJson(await myBackend.fetchUqpayToken()),
  );

  // 2. Create the intent on YOUR server. Amounts are decimal strings in major
  //    units — "8.98", never 898.
  final returnUrl = Uri.parse('myapp://payment-return');
  final intentId = await myBackend.createPaymentIntent(
    amount: '8.98',
    currency: 'SGD',
    returnUrl: returnUrl,
  );

  // 3. Show the sheet. It returns a result; it never throws for a decline.
  if (!context.mounted) return;
  final result = await UqpayPaymentSheet.present(
    context,
    payments: uqpay.payments,
    intentId: intentId,
    returnUrl: returnUrl,
  );

  // 4. Handle every outcome — the switch is exhaustive, so a new SDK version
  //    cannot silently add a case you forgot.
  switch (result) {
    case UqpayPaymentCompleted():
      // A UX signal only. Fulfil after your server re-reads the intent.
      showThankYou();
    case UqpayPaymentFailed(:final error):
      showError(error.userMessage, retryable: error.isRetryable);
    case UqpayPaymentCanceled():
      showCancelled();
    case UqpayPaymentPending(:final intentId):
      // The payment may still succeed. Ask your server later.
      showPending(intentId);
  }
}
```

`myBackend` stands for your own API client. Your server does two things the
app cannot: it holds the API key, and it creates the payment intent with the
amount from **its** order record — the app sends an order reference, never a
price. The [integration guide](doc/integration-guide.md#the-backend-contract)
has the backend contract.

"Fulfil from your webhook" in the `Completed` case means: fulfil from your
**server**, after it has retrieved the intent from the UQPAY API. A webhook is
only the prompt to do that, never proof on its own (see
[Security](#security-checklist-for-production)).

### Startup

The quickstart calls `init` inside `checkout()` so it reads top to bottom. In
a real app:

- **Create one `UqpaySdk` at app start and keep it** wherever your app keeps
  long-lived services. `init` performs no I/O and holds no global state, but
  each handle has its own token cache, so a handle created per payment
  fetches a fresh token every time. Two handles for two environments can
  coexist.
- **Call `uqpay.payments.reconcileUnresolved()` once at startup**, after
  `init` (and after sign-in, if your token endpoint needs a session), before
  offering a new payment. It settles payments interrupted by process death —
  see [Pending and reconciliation](#pending-and-reconciliation).
- **On web, call `UqpayReturnHandler.consume(Uri.base)` once at startup.** A
  full-page redirect reloads your app; this resolves the payment that was in
  flight. It returns `null` when the app was not opened by a return — see
  [3-D Secure and return URLs](#3-d-secure-and-return-urls).
- **Use a return URL that fits the platform.** `myapp://payment-return` works
  on Android and iOS, where the in-app webview catches it. On web the return
  URL must be an `https` page of your own web app. Register the same URL on
  the intent your server creates.

```dart
final returnUrl = kIsWeb
    ? Uri.parse('https://shop.example.com/checkout/return')
    : Uri.parse('myapp://payment-return');

// Once, after init — e.g. from your root widget's initState.
Future<void> settlePaymentsOnLaunch(UqpaySdk uqpay) async {
  if (kIsWeb) {
    final returned =
        await UqpayReturnHandler(payments: uqpay.payments).consume(Uri.base);
    if (returned != null) {
      // Back from a redirect: the server's current view of that intent.
      // Check returned.intentId is your order before acting on it.
    }
  }
  for (final result in await uqpay.payments.reconcileUnresolved()) {
    // Show a receipt or "processing" for result.intentId; your server fulfils.
  }
}
```

## Handling the result

Every payment operation **returns** its outcome — it never throws for a
decline, a cancel, a timeout, a 4xx or a 5xx. Exceptions are reserved for
programmer error at call time: an `ArgumentError` naming the field (empty
intent id, missing `tokenProvider`, `http://` base URL, an invalid
`presentation`) or an `UnsupportedError` on desktop.

`UqpayPaymentResult` is a sealed class with four cases, **frozen for the 1.x
line**. New outcomes arrive as new error codes or cancel reasons inside the
existing cases, never as a fifth case.

| Case | Means | What to do | Fields |
|---|---|---|---|
| `UqpayPaymentCompleted` | The intent is `SUCCEEDED`, or `REQUIRES_CAPTURE` (authorised; your side captures). | Show a receipt. Fulfil only after your server has retrieved the intent. | `intentId`, `intent` (never null), `status`, `attempt` |
| `UqpayPaymentFailed` | The payment did not go through — **unless `error.isOutcomeUnknown`**. | Show `error.userMessage`; offer a retry when `error.isRetryable`. If `error.isOutcomeUnknown`, treat it as `Pending`. | `intentId`, `error`, `intent?` |
| `UqpayPaymentCanceled` | Nothing was charged: the customer dismissed the sheet or tapped Cancel before a confirm left the device, your code cancelled, or the intent was already cancelled server-side. | Return the customer to checkout. | `intentId`, `reason` (`UqpayCancelReason`, an open type), `intent?` |
| `UqpayPaymentPending` | The outcome is **not known on the device**. | Show "processing". Never show failure, never charge again. [Reconcile](#pending-and-reconciliation). | `intentId`, `lastKnownStatus?`, `intent?`, `cause?`, `reconcile()` |

Notes that matter in production:

- **Amounts are never rescaled.** `intent.amount` is a `UqpayAmount` built
  from the server's decimal string in major units (`"8.98"`); format it with
  `format(currencyCode:)`. The SDK does no amount arithmetic, and neither
  should you on the client.
- **Manual capture.** `Completed` with `status == UqpayIntentStatus.requiresCapture`
  means authorised, not captured. Decide on capture from the intent your
  server retrieves.
- **A confirm in flight is never reported as cancelled.** Dismissing the sheet
  after the confirm has left the device resolves `Pending`.
- **One sheet per intent.** Calling `present` again for an intent whose sheet
  is still open — presented or embedded — returns `Failed` /
  `invalid_configuration` immediately instead of opening a second sheet.
  Changing an embedded sheet's `intentId`, `payments`, `presentation` or
  `allowedPaymentMethods` ends the old payment (its `onResult` gets
  `Canceled` or `Pending`) and starts a new one; other property changes need
  the widget re-keyed.
- **A sheet dismissed while a successful payment is being finalised reports
  the payment's real result**, never a fabricated `Canceled`.
- **`present` needs `MaterialLocalizations`** above the context you pass.
  Every `MaterialApp` has them. In a `CupertinoApp` or `WidgetsApp`, add
  `DefaultMaterialLocalizations.delegate` (or
  `GlobalMaterialLocalizations.delegate`) to `localizationsDelegates`;
  otherwise `present` throws a `StateError` before showing anything. The
  embedded `UqpayPaymentSheet` widget supplies default English Material
  localizations itself.

### Pending and reconciliation

`Pending` means the device cannot tell whether the money moved: the outcome
deadline passed while the intent was still in flight (5 minutes of active
waiting for cards, 10 for wallets, background time excluded), the confirm's
response was lost and the replays could not settle it, the customer closed the
3-D Secure page, or the sheet was dismissed mid-confirm. **Never show the
customer a failure and never charge again.**

Settle it now:

```dart
if (result case UqpayPaymentPending(:final reconcile)) {
  // One GET of the intent; maps the SERVER's status to a result.
  final settled = await reconcile();
}
```

And settle it on the next launch if the app was killed first. The SDK
persists an idempotency pin to `shared_preferences` before every confirm
leaves the device, so it knows which intents were in flight:

```dart
// Once at startup, after init, before offering a new payment.
final leftovers = await uqpay.payments.reconcileUnresolved();
for (final result in leftovers) {
  // Completed / Failed / Canceled are final; Pending is still in flight.
}
```

`reconcileUnresolved()` reads every unexpired pin (24 h) in this environment,
reconciles each intent against the server and releases the pins of resolved
ones. `unresolvedIntentIds()` gives you the ids without reconciling. Either
way, your server's view of the intent is the one you fulfil from. The
[integration guide](doc/integration-guide.md#surviving-process-death) covers
web page reloads and 3-D Secure returns as well.

### Errors

Every `UqpayPaymentFailed` carries a `UqpayError`:

| Field | |
|---|---|
| `code` | A `UqpayErrorCode`. An **open** type: a code this SDK version does not know arrives with `isUnknown == true` and the server's string in `raw`. Write your `switch` with a `default`. |
| `userMessage` | Safe to show the customer as-is. |
| `developerMessage` | For your logs. Never contains a token, PAN, CVC, expiry or cardholder name. |
| `isRetryable` | Whether the same request may be sent again. The SDK reuses the same idempotency key. |
| `isOutcomeUnknown` | Whether the payment may have been taken anyway. Reconcile before letting the customer pay again. |
| `serverCode`, `serverMessage`, `httpStatus` | The raw server code and HTTP status, when there was one. |
| `traceId`, `responseId` | From `x-trace-id` / `x-response-id`. Quote these to UQPAY support. |

**[ERROR_CODES.md](ERROR_CODES.md)** is the full table — every code, when it
happens, what to do and the exact message shown to the customer. It is
generated from the code, so it cannot drift.

## Configuration

### `UqpaySdk.init`

| Parameter | Type | |
|---|---|---|
| `environment` | `UqpayEnvironment` | **Required.** `sandbox` (`https://api-sandbox.uqpaytech.com`) or `production` (`https://api.uqpay.com`). Choose it from explicit per-build configuration, not `kDebugMode` — see [sandbox vs production](doc/integration-guide.md#sandbox-vs-production). |
| `tokenProvider` | `Future<UqpayAuthToken> Function()` | Fetches a fresh token from **your** server. The SDK calls it lazily, caches the token until shortly before expiry, de-duplicates concurrent calls, and calls it exactly once more when the API answers 401. The value is trimmed and must be visible ASCII (it is sent as a header); anything else is reported as `authentication_failed` without a request. May be omitted while wiring up; accessing `uqpay.payments` then throws an `ArgumentError` naming `tokenProvider`. |
| `clientId` | `String?` | **Optional.** Your UQPAY client id, sent as `x-client-id` only when set. An identifier, not a secret. The sandbox accepts confirms without it; send it when your backend returns it. |
| `onBehalfOf` | `String?` | A UQPAY Connect sub-account id, sent as `x-on-behalf-of` on every request. See [Connect sub-accounts](doc/integration-guide.md#connect-sub-accounts). |
| `baseUrlOverride` | `String?` | A bare `https` origin (`https://host` or `https://host:port`, no path, query or credentials) replacing the environment's. Anything else, including `http://`, throws `ArgumentError` at `init`. Leave unset in production. |
| `loggingEnabled` | `bool` | Default `false`. See below. |
| `logHandler` | `void Function(String line)?` | Where log lines go when logging is enabled; `null` means `dart:developer`. |

**`UqpayAuthToken.fromJson`** accepts the token endpoint's wire shape
verbatim: `{"auth_token": "…", "expired_at": 1765941179}` (`expired_at` in
epoch seconds, optional). Without `expired_at` the SDK assumes a 20-minute
lifetime, shorter than UQPAY's 30, and refreshes accordingly. If your provider
throws, returns an empty token, or does not answer within 30 seconds, the
payment resolves `Failed` / `authentication_failed` (retryable) when nothing
has been sent yet, and reconciles from the server if a confirm had already
left — never a crash and never a hang.

**Logging.** With `loggingEnabled: true` the SDK logs the HTTP method, path
and status code of every request, the `x-trace-id` to quote to support, the
intent id, every flow phase transition and the class name of any unexpected
exception. It **never** logs a request or response body, card number, CVC,
expiry, cardholder name or token. Lines go to `logHandler` when supplied,
otherwise to `dart:developer` `log(name: 'uqpay')`, visible in DevTools and
`flutter run` output. A throwing handler is swallowed. Keep logging off in
release builds unless you route `logHandler` to your own redacted logger:

```dart
final uqpay = UqpaySdk.init(
  environment: UqpayEnvironment.sandbox,
  tokenProvider: fetchToken,
  loggingEnabled: kDebugMode,
  logHandler: (line) => myLogger.debug('uqpay: $line'),
);
```

### `UqpayPaymentSheet.present`

`present(context, ...)` pushes the sheet as a modal bottom sheet on the root
navigator and completes with exactly one `UqpayPaymentResult`, after the
sheet has finished closing. The same parameters exist on the embeddable
`UqpayPaymentSheet(...)` constructor, which delivers the result through
`onResult`.

| Parameter | Type | |
|---|---|---|
| `payments` | `UqpayPayments` | **Required.** `uqpay.payments`. |
| `intentId` | `String` | **Required.** Created by your server. |
| `returnUrl` | `Uri` | **Required.** The `return_url` registered on the intent at creation. See [3-D Secure and return URLs](#3-d-secure-and-return-urls). |
| `allowedPaymentMethods` | `Set<String>?` | Restrict the method list. Default `null` = no restriction. See [below](#presentation-and-allowed-methods). |
| `presentation` | `UqpaySheetPresentation` | `methodList()` (default), `cardOnly()` or `singleWallet('alipaycn')`. See [below](#presentation-and-allowed-methods). |
| `billingDetails` | `UqpayBillingDetails?` | Prefills the card form's name (from `firstName` + `lastName`), email and billing address. `phoneNumber` is not on the form; it is sent as given. The customer can edit every prefilled value; what is sent is what the form holds when they tap pay. Card number, expiry and CVC are deliberately not prefillable. |
| `appearance` | `UqpayAppearance?` | Theming overrides. See [Appearance](#appearance). |
| `localizations` | `UqpayLocalizations?` | String overrides for this sheet. See [Localizations](#localizations). |
| `challengePresenter` | `UqpayChallengePresenter?` | How 3-D Secure is shown. `null` picks the platform default: an in-app webview on Android/iOS, a full-page redirect on web. |
| `useRootNavigator` | `bool` | Default `true`. |
| `clock` | `UqpayClock?` | Time source for QR countdowns; tests inject a fake. |

Behaviour you can rely on:

- **Dismissal.** System back, swipe-down on the handle, tap-outside, the close
  button and a programmatic `Navigator.pop` all go through one path:
  `Canceled` before a confirm has left the device, `Pending` once it has.
  While the confirm is actually in flight the sheet refuses to close and says
  why.
- **Terminal intents** show their result immediately and never render a form.
- **Lifecycle.** Polling pauses when the app leaves the foreground and
  reconciles once, immediately, on resume. Background time never counts
  against the outcome deadline.
- **Polling budget.** After a confirm the SDK reads the intent on a
  back-off that starts at 2 s and grows to 10 s between reads, with a small
  jitter, until the server answers or the outcome deadline is spent (5 min
  for a card / 3-D Secure flow, 10 min for a QR wallet). That is at most
  about 40 reads for a card and about 75 for a wallet; a deadline ends in
  `Pending`, never in a guess.
- **Theme.** Light and dark follow the host `ThemeMode`; the sheet never
  forces a brightness.
- **Web** never renders the card form (see [Limitations](#limitations)); the
  sheet offers the intent's wallet/QR methods and says so on screen.

### Presentation and allowed methods

`allowedPaymentMethods` is intersected with the intent's
`available_payment_method_types`. Unknown names are ignored. If the
intersection is empty the sheet shows its "No payment methods are available"
screen, and closing it resolves `Canceled`.

`UqpaySheetPresentation` is sealed and frozen for 1.x:

| | |
|---|---|
| `UqpaySheetPresentation.methodList()` | The default. The customer picks from every method the intent offers (filtered by `allowedPaymentMethods`). |
| `UqpaySheetPresentation.cardOnly()` | Skips the list and opens the card form. There is no list to go back to, so closing the sheet cancels the payment (`Canceled` before a confirm has left, `Pending` after). Throws `ArgumentError` if `allowedPaymentMethods` is set and excludes `card`. If the intent does not offer `card`, or the sheet runs in a browser, the "no payment methods" screen is shown. |
| `UqpaySheetPresentation.singleWallet('alipaycn')` | Confirms that wallet as soon as the intent is loaded and shows its QR code or instructions. `singleWallet('card')` throws `ArgumentError` — use `cardOnly()`. Naming a method outside `allowedPaymentMethods` throws `ArgumentError`. If the intent does not offer the method, the "no payment methods" screen is shown. |

```dart
final result = await UqpayPaymentSheet.present(
  context,
  payments: uqpay.payments,
  intentId: intentId,
  returnUrl: returnUrl,
  allowedPaymentMethods: const {'card', 'alipaycn', 'wechatpay'},
  presentation: const UqpaySheetPresentation.singleWallet('alipaycn'),
);
```

Prefilling billing details (field names as in `UqpayBillingDetails`):

```dart
billingDetails: const UqpayBillingDetails(
  firstName: 'Ada',
  lastName: 'Lovelace',
  email: 'ada@example.com',
  phoneNumber: '+65 6123 4567',
  address: UqpayAddress(
    countryCode: 'SG',
    city: 'Singapore',
    street: '1 Test Street, #01-01',
    postcode: '018956',
  ),
),
```

### Test-mode banner

Whenever the SDK was initialised with `UqpayEnvironment.sandbox`, the sheet
draws a **"TEST MODE — no real money will move"** banner at the top. No flag
or `UqpayAppearance` setting turns it off, and it never appears in
production. If you see it in a build
you meant to be production, your environment selection is wrong — fix that
before release.

### Appearance

With no `UqpayAppearance` the sheet derives everything from the host
`Theme`. Each field is an override layered on top:

```dart
UqpayPaymentSheet.present(
  context,
  // …
  appearance: UqpayAppearance(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
    cornerRadius: 4,
    textTheme: myTextTheme,
    payButtonStyle: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
  ),
);
```

Supply a `colorScheme` whose brightness matches the host theme's; the sheet
does not flip brightness for you.

### Localizations

`UqpayLocalizations` is the English string catalogue. Subclass it and
override what you need, then pass the instance to `present(localizations:)`
for one sheet, or register your own `LocalizationsDelegate<UqpayLocalizations>`
in `MaterialApp.localizationsDelegates` ahead of
`UqpayLocalizations.delegate` for the whole app:

```dart
class GermanUqpayStrings extends UqpayLocalizations {
  const GermanUqpayStrings();
  @override
  String get paySheetTitle => 'Zahlung';
  @override
  String get cardNumberLabel => 'Kartennummer';
}

// One sheet:
UqpayPaymentSheet.present(
  context,
  // …
  localizations: const GermanUqpayStrings(),
);

// The whole app: a delegate, listed in localizationsDelegates.
class GermanUqpayDelegate extends LocalizationsDelegate<UqpayLocalizations> {
  const GermanUqpayDelegate();
  @override
  bool isSupported(Locale locale) => locale.languageCode == 'de';
  @override
  Future<UqpayLocalizations> load(Locale locale) =>
      SynchronousFuture(const GermanUqpayStrings());
  @override
  bool shouldReload(GermanUqpayDelegate old) => false;
}
```

Registering any delegate is optional: without one, the sheet uses the
built-in English catalogue.

Exact wording and the sheet's visual design are not part of the stability
contract; if you depend on precise wording, supply your own strings.

## 3-D Secure and return URLs

`returnUrl` must be the `return_url` your server registered on the intent.
The SDK uses it only as a **navigation sentinel** to recognise the end of a
challenge — scheme, host and path prefix; extra query parameters are allowed
and never read for a payment status. Put no secret, token or order data in it.

**Android and iOS.** The challenge opens in an in-app webview page
(`UqpayChallengePage`, pushed by `UqpayWebviewChallengePresenter`). Only a
main-frame navigation to the return URL (or to the return URL's own app
scheme) ends the browser step. Links to other non-web schemes — a banking
app, `tel:`, `mailto:`, `intent:` — open externally and the challenge page
stays up; navigations inside iframes never end it. Because the webview
recognises the return navigation itself, **no URL scheme registration is
needed** in `Info.plist` or `AndroidManifest.xml`; a custom scheme such as
`myapp://payment-return` works as-is. The challenge page has a 10-minute
timeout that restarts after the app has been in the background and comes
back to the foreground, so approving in a banking app for longer than that
cannot time the challenge out by itself. When the page closes, on any exit
path (return, close, back, timeout or flow cancel), the SDK clears that
webview's **cache and local storage**. It does not clear cookies: the
platform cookie API is app-global and would also sign your own webviews out.
Cancelling the flow (`flow.cancel()`, or dismissing the sheet) pops the
challenge page.

**Web.** Web has no card form in this version, so the sheet never runs a
card 3-D Secure challenge in a browser. A redirect happens on web only when a
redirect-based (non-card) method answers the confirm with a `redirect_to_url`
next action, or when your own headless code confirms a card on web. On web
only `redirect_to_url` is supported in this version: a `redirect_iframe` next
action (a self-submitting POST form) cannot be turned into a same-tab
redirect, so the web presenter (`UqpayRedirectChallengePresenter`) reports it
as an `invalid_configuration` failure instead of navigating. QR and bank-transfer methods render in the sheet and never
redirect. A redirect is a full page in the same tab, never a popup or an
iframe, so popup blockers and third-party-cookie restrictions cannot break
it. The `return_url` must therefore be an `https` page of your web app.
Before redirecting, the SDK persists the in-flight intent id in
`localStorage`; on the return reload, call `UqpayReturnHandler.consume(Uri.base)`
once at startup. If your web checkout can never redirect, `consume` just
returns `null`, so calling it unconditionally on web is safe:

```dart
final handler = UqpayReturnHandler(payments: uqpay.payments);
final result = await handler.consume(Uri.base);
if (result != null) {
  // The customer just came back from a challenge. `result` is the server's
  // current view of that intent — Completed, Failed, Canceled or Pending.
}
```

Before acting on `result`, check that `result.intentId` is an order of yours
— ideally the one this session was paying. A crafted return URL can name any
intent id.

If your backend can template the return URL per intent, register
`UqpayReturnHandler.returnUrlFor(returnUrl, intentId)`, which appends
`uqpay_intent=<id>` so the return leg identifies the intent even in a fresh
browser. The parameter is a routing hint only; the status is always fetched
from the server.

**The outcome is a signal, not a result.** Whatever the presenter reports —
returned, dismissed, failed, timed out — the flow re-queries the intent and
maps the **server's** status. A customer who closes the challenge page may
already have authenticated; the sheet keeps waiting, and dismissing it then
resolves `Pending`. To present the challenge another way (a Custom Tab, your
own webview), implement `UqpayChallengePresenter` and pass it as
`challengePresenter`.

## Headless API

Import `package:uqpay_sdk_flutter/headless.dart` to build your own checkout
UI. It exports no widgets, so `UqpayWebviewChallengePresenter` (which pushes
a page) is available only from `package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart`;
import that library instead if you use it, as the sample below does. The API
is `uqpay.payments` (`UqpayPayments`):

| Method | |
|---|---|
| `retrieveIntent(id)` | `GET` the intent: amount, currency, `availablePaymentMethodTypes`, status. Returns `UqpayIntentRetrieved(intent)` or `UqpayIntentUnavailable(error)`. |
| `confirm(id, request, {outcomeDeadline})` | Reads the intent first (a terminal or authorised intent returns immediately without confirming), persists an idempotency key, sends the confirm, replays a lost response with the same key and byte-identical body (3 / 6 / 10 s), then polls for the outcome. |
| `createFlow({intentId, request, outcomeDeadline, challengePresenter})` | The same as `confirm` but with a `status` stream, `cancel()`, `pause()` / `resume()`, and automatic 3-D Secure presentation when you pass a presenter. Without one, the flow surfaces the `next_action` on `status` and you present it. |
| `awaitOutcome(id, {deadline})` | Polls an already-confirmed intent (after a redirect, a QR scan, or a `Pending`) without sending a confirm. |
| `reconcile(id)` | One `GET`, mapped to a result. `REQUIRES_PAYMENT_METHOD` with no attempt is `Pending` (nothing has been paid yet); a settled declined attempt is `Failed`. Never throws. |
| `cancelIntent(id, {cancellationReason})` | A **server** cancel (`POST …/cancel`). Distinct from `flow.cancel()`, which sends nothing. The gateway acknowledges with the intent's previous status and `cancellation_reason` set, and flips it to `CANCELLED` a few seconds later; both are reported as `Canceled` (`merchantCancelled`). A cancel of an already paid intent returns `Completed`. |
| `unresolvedIntentIds()` / `reconcileUnresolved()` | Intents with an unexpired idempotency pin from a previous run. |
| `close()` | Releases HTTP connections. |

A card confirm must carry what the gateway requires:

- **`network`.** The gateway rejects a card confirm without
  `payment_method.card.network` as `invalid_payment_method: invalid card
  network`. Leave `network` null and `UqpayCardDetails` fills it from the PAN
  via `UqpayCardBrand.detect`; pass it explicitly only to override. Only a
  PAN outside every known BIN range is sent without a network.
  `UqpayCardBrand` is public — `UqpayCardBrand.detect(digits)`, which
  returns a `UqpayCardBrand?` (`null` for an unknown range), plus
  `wireName`, `displayName`, `cvcLength`, `validLengths`, `maxLength` — so
  your form can show the brand, pick the CVC length and cap the input the way
  the sheet does.
- **Billing.** `billing.firstName`, `billing.lastName` (derived from the
  cardholder name when you leave them `null`), `billing.email` and
  `billing.address.countryCode`, `city`,
  `street` and `postcode` are required; `state` is required for some
  countries (US yes, SG no — the gateway decides; the sheet asks for it for
  US, CA, AU, IN, BR and MX and omits it when empty). Empty strings are
  rejected like missing fields. The sheet collects all of these; a headless
  integration must too.
- **`browserInfo`.** The 3-D Secure risk snapshot. Build it once per attempt
  and reuse it on retries so the replayed body stays byte-identical (the
  idempotency key itself does not depend on it, so a retry from a new
  session still finds its key). Never
  fabricate values; omit what you do not know. `mobile.osType` is uppercase
  (`IOS`, `ANDROID`). `ipAddress` may be left null — the SDK fills it with
  the device's own interface address when it can. The gateway rejects a
  **card** confirm without one, so when no address can be determined (web,
  no network interface) the flow fails locally with `invalid_configuration`
  before sending anything; supply `UqpayConfirmRequest.ipAddress` yourself
  in that case. Wallet confirms are sent without it.
- **Card holder name.** At most 128 characters (the gateway's limit);
  longer names are rejected locally with an `ArgumentError`.

```dart
// The full library: UqpayWebviewChallengePresenter is not in headless.dart.
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

final request = UqpayConfirmRequest(
  paymentMethod: UqpayConfirmPaymentMethod.card(
    UqpayCardDetails(
      cardName: 'Ada Lovelace',
      cardNumber: pan,        // digits only, 12–19
      expiryMonth: '12',      // "MM"
      expiryYear: '2033',     // "YYYY"
      cvc: cvc,
      // network: detected from the PAN when omitted.
      billing: const UqpayBillingDetails(
        firstName: 'Ada',
        lastName: 'Lovelace',
        email: 'ada@example.com',
        address: UqpayAddress(
          countryCode: 'SG',
          city: 'Singapore',
          street: '1 Test Street, #01-01',
          postcode: '018956',
        ),
      ),
    ),
  ),
  browserInfo: UqpayBrowserInfo(
    browser: const UqpayBrowserDetails(userAgent: 'MyApp/1.0 (iPhone)'),
    deviceId: sessionDeviceId, // a per-install or per-session id you generate
    language: 'en-SG',
    mobile: const UqpayMobileDetails(
      deviceModel: 'iPhone',
      osType: 'IOS',
      osVersion: 'iOS 17.2',
    ),
    screenHeight: 852,
    screenWidth: 393,
    timezone: '8',            // UTC offset in whole hours, as a string
  ),
);

final flow = uqpay.payments.createFlow(
  intentId: intentId,
  request: request,
  challengePresenter: UqpayWebviewChallengePresenter(
    navigator: () => Navigator.of(context),
  ),
);
flow.status.listen((s) => showProgress(s.phase, s.nextAction));
final result = await flow.confirm();
```

Wallet confirms use `UqpayConfirmPaymentMethod.wallet('paynow', const UqpayWalletDetails())`
and surface a `display_qr_code` or `display_bank_details` next action on the
status stream for you to render. The wallet request models are marked
**experimental** in [STABILITY.md](STABILITY.md#7-what-is-not-covered)
because their wire shape has not been proven against sandbox for every method.

`UqpayCardDetails.toString()` prints only the network and last four digits;
nothing in the SDK logs, persists or copies the other fields.

## Sandbox testing

Sandbox credentials come from <https://app-sandbox.uqpaytech.com> → Developer
→ API Keys. Sandbox and production credentials are separate and not
interchangeable.

**Test cards** for the sandbox gateway. Use exactly the expiry and CVC
listed:

| Card | Number | Expiry | CVC | Result |
|---|---|---|---|---|
| UnionPay | `6250 9470 0000 0014` | **12/33** | **123** | No 3-D Secure; intent `SUCCEEDED`. Use it for the success path. |
| Mastercard, 3DS | `5521 9700 7999 8012` | **10/28** | **001** | The only 3DS-enrolled card: the challenge opens and authenticates (3DS `Y`), then `Completed`, intent `SUCCEEDED`. Use it for the 3-D Secure success path. |
| Mastercard, 3DS fails | `5413 3300 5700 4047` | **12/30** | **989** | `Failed` / `3ds_failed`. Use it for the failure path. |
| Visa | any | — | — | `system_error`. |

**Declines cannot be forced in sandbox.** The sandbox currently offers no
card, amount or other trigger that produces an issuer decline such as
`card_declined` or `insufficient_funds`, or any other specific decline
reason. The table above lists every outcome the sandbox test cards
produce. Test your handling of the other codes with unit tests over the
SDK's typed results instead: construct `UqpayPaymentFailed` with the
`UqpayErrorCode` you want to exercise (see
[Unit testing your checkout](doc/integration-guide.md#unit-testing-your-checkout)). The
SDK's own failure matrix in
[`test/payment_flow_test.dart`](test/payment_flow_test.dart) (group
`failure matrix — headless cells`) shows the pattern of scripting each wire
response and asserting the typed result.

**Wallets.** Which wallets return a QR code (`display_qr_code`) in sandbox
depends on the payment methods enabled on your sandbox account; confirm your
enabled methods with UQPAY. On a sandbox account with wallets enabled, these
returned a QR code for an SGD 1.00 intent: `alipaycn`, `wechatpay`,
`alipayhk`, `tng`, `gcash`, `dana`, `kakaopay`, `truemoney`, `unionpay`.

A wallet that is not enabled on your account is rejected by the gateway. The
SDK reports it as `Failed` carrying the server's own code (for example
`error.code.raw == 'system_error'`, `isUnknown == true`), never as a QR.

Other sandbox facts that otherwise look like SDK bugs:

| | |
|---|---|
| **Tokens** | One active token per merchant. A colleague (or a second backend, or the native demo apps) minting a token invalidates yours; every call then fails `authentication_failed`. Run one backend. |
| **QR wallets** | **Sandbox QR wallets settle on real rails.** Scanning a sandbox QR with a real wallet app moves real money. Never scan one casually. |
| **Intent `description`** | Required, maximum 32 characters. The gateway answers 33+ with a bare `invalid_parameter` that does not name the field. |
| **Webhooks** | UQPAY has not yet published a signature scheme. Treat a webhook as a hint and re-read the intent server-side. |

To test your result handling without a network, a simulator or sandbox
credentials, see
[Unit testing your checkout](doc/integration-guide.md#unit-testing-your-checkout).
The [example app](example/) is a runnable sandbox checkout for trying each
result on a device.

## Security

**An API key inside your app is a compromise, not a configuration.** Anything
shipped in an APK, IPA or web bundle can be extracted, and a UQPAY API key
grants full merchant access — refunds, payouts, balances — to whoever holds
it. The SDK holds **no API key** and has no parameter that accepts one. It
authenticates every request with a short-lived token that **your backend**
obtains from `POST /api/v1/connect/token` and hands to the app; the SDK never
calls that endpoint and never sees those credentials.

### What the auth token can do

Read this before you go live. The token your backend mints with
`POST /api/v1/connect/token` is not scoped to one payment. It is the
merchant's **single, full-scope access token** — UQPAY allows one active
token per merchant, and it is the same token your server uses for its own
API calls. Handing it to the app therefore means that anyone who extracts it
from a device (a proxy on their own phone, the browser's network tab on web,
a debugger on a rooted device) can call **other UQPAY merchant APIs** with it
until it expires or your server mints a new one. Until UQPAY offers a
narrower credential:

- **Ask UQPAY for a scoped, intent-level credential** for client-side use,
  and get written confirmation of what the connect token can access.
- **Keep the token's lifetime short** and re-mint it if you suspect it was
  extracted (minting a new token invalidates the old one).
- **Never expose your token endpoint without authenticating the user's
  session**, and rate-limit it per user.

**Reporting a vulnerability.** Do not open a public issue. Follow
[SECURITY.md](SECURITY.md), which uses GitHub's private vulnerability
reporting.

### Other guarantees

- **HTTPS only.** A non-`https` origin is rejected at `UqpaySdk.init`, before
  any request can be sent.
- **No card data at rest.** The card number, CVC, expiry and cardholder
  name are never written to `shared_preferences`, files, cookies or
  `localStorage`, on any platform. The only things stored are idempotency
  pins and the in-flight intent id of a web redirect, removed once the
  attempt resolves. A pin holds the intent id, the idempotency key, a
  timestamp, optionally the device IP the SDK sent, and a 64-bit
  non-reversible hash (FNV-1a, not cryptographic) of the confirm request
  taken after the card number is cut to its first six and last four digits,
  the CVC is removed and the 3-D Secure browser snapshot is left out. The
  hash therefore depends on the expiry, cardholder name and billing details,
  but none of them can be read back from it. See [PRIVACY.md](PRIVACY.md).
- **No card data in logs.** Card numbers appear in any output only masked to
  the last four digits; a redaction test runs the full confirm through a
  capturing `debugPrint` and asserts it. Diagnostic logging, when enabled,
  carries identifiers and status words only.
- **No certificate pinning**, deliberately: a certificate rotation would turn
  into a total outage for every installed app with no server-side remedy.
  The platform enforces TLS and validates the chain.
- **No third-party analytics, crash or ad SDKs**, and no network call to any
  host other than the configured UQPAY environment — except that a wallet QR
  image supplied as `qr_code_url` is downloaded by the sheet only when it is
  an `https` URL on a UQPAY domain (`uqpay.com`, `uqpaytech.com` or a
  subdomain); any other `qr_code_url` is ignored.
- **The result is a UX signal, not proof of payment.** It can be spoofed on a
  rooted or jail-broken device, and after a 3DS challenge or a wallet hand-off
  the SDK may only ever see `Pending`.

What the SDK collects and what leaves the device, for Apple's privacy label
and Play's Data Safety form: [PRIVACY.md](PRIVACY.md).

### Security checklist for production

**Credentials**

- **The auth token is the merchant's full-scope credential** (see
  [What the auth token can do](#what-the-auth-token-can-do)). Your token
  endpoint requires your own signed-in user session, is rate-limited, and is never
  callable anonymously.
- **No UQPAY API key in the app** — not in the bundle, not in a
  `--dart-define`, not in a remote config the app downloads.
- **Tokens are never logged** — not on your server, not in the app, not
  in crash reports. `UqpayAuthToken.toString()` redacts the value.

**Payment intents**

- **Intents are created server-side only**, with the amount and currency
  from your own order record. The app sends an order reference.
- **Your server confirms every payment before fulfilling** by retrieving
  the intent (`GET /api/v2/payment_intents/{id}`). Never ship because the
  SDK said `Completed`.
- **Webhooks are a hint, for now.** Until UQPAY publishes a signature
  scheme, a webhook is a prompt to re-fetch the intent, never proof.
- **`Pending` means unknown.** No success, no failure, no second charge.
  Treat `Failed` with `isOutcomeUnknown` the same way.
- **Manual capture state lives on your server.**

**App configuration**

- **Sandbox vs production is an explicit build setting** (a flavour or a
  `--dart-define`), not `kDebugMode`. The test-mode banner tells you
  which one a build is talking to.
- **`baseUrlOverride` is unset** in production builds.
- **Logging is off** in release builds, or routed to your own redacted
  logger.
- **No secret or order data in the return URL.**

## Limitations

This package ships zero first-party native code — no `android/`, no `ios/`,
no platform channels. That is a deliberate design choice (one Dart codebase,
no native build breakage, works on web), and it means the following are **not
supported** in 1.0.0. Read this list before integrating, not after.

| Not supported | Why | What to do instead |
|---|---|---|
| **Apple Pay / Google Pay** | Both need native platform APIs and entitlements. | On the roadmap: adding Google's `pay` plugin (Apache-2.0) is proposed and pending sign-off. Until then, merchants who need wallets today use the native UQPAY iOS SDK. |
| **Native WeChat / Alipay app hand-off** (open the wallet app, return via SDK callback) | Requires the vendors' native SDKs. | Merchant-presented **QR** and payment instructions in-sheet; the customer scans with their wallet app. |
| **Card entry on web** | Card fields rendered inside your own origin typically move a merchant from PCI SAQ A to SAQ A-EP. | Web offers the intent's wallet/QR methods only and states the limitation on screen. Test cards on Android or iOS. |
| **`FLAG_SECURE` / screenshot blocking** on the card form | Android-native only. | Set it in your own `Activity` if you need it. |
| **Certificate pinning** | Requires platform trust APIs, and pinning is a well-known cause of total payment outages when a certificate rotates. The platform already enforces TLS and validates the chain. | None needed. Pinning is an explicit non-goal, not a gap we intend to close. |
| **Desktop** (macOS / Windows / Linux) | Out of scope. | `UqpaySdk.init` throws an `UnsupportedError` naming the platform, so a desktop build fails loudly and early rather than half-working. |

Also note: the wallet confirm request models are experimental (see
[STABILITY.md](STABILITY.md#7-what-is-not-covered)), and the pure-Dart device
snapshot sent for 3-D Secure risk carries no native identifiers — the device
id is a random per-session value and the OS version is not read.

## Compatibility

| SDK version | UQPAY API version | Dart | Flutter | Android | iOS | Web |
|---|---|---|---|---|---|---|
| 1.0.0-rc.x | Payments API v2 (`/api/v2/payment_intents/...`); your backend mints tokens with v1 `/api/v1/connect/token` | `^3.11.0` | `>=3.41.0` (stable N-2) | minSdk 24 | 13.0+ | Last 2 versions of Chrome, Safari, Firefox, Edge, incl. iOS Safari; JS and Wasm builds. Requires the UQPAY API to accept CORS pre-flights from your origin — see [Web: CORS and origin setup](doc/integration-guide.md#web-cors-and-origin-setup) |

The Flutter floor is "stable N-2": the current stable and the two prior minors.
CI builds and tests at both the floor and the newest stable. Floors are subject
to ratification before 1.0.0; raising one afterwards is a minor version bump,
announced in the changelog.

## Documentation

| Document | What's in it |
|---|---|
| [Integration guide](doc/integration-guide.md) | The long form of this page: backend contract, token lifetime, intent fields, sandbox vs production, confirming server-side, process death, return URLs, Connect sub-accounts, unit testing your checkout. |
| [Troubleshooting](doc/troubleshooting.md) | Symptom → cause → fix. |
| [ERROR_CODES.md](ERROR_CODES.md) | Every error the SDK can report, what causes it, what to do, and the exact message shown to the customer. Generated from the code. |
| [STABILITY.md](STABILITY.md) | What counts as public API, what counts as a breaking change in Dart, the deprecation window, and the supported Flutter range. |
| [PRIVACY.md](PRIVACY.md) | What the SDK collects and what leaves the device — enough to fill in Apple's privacy label and Play's Data Safety form. |
| [CHANGELOG.md](CHANGELOG.md) | Every release. |
| [`example/`](example/) · [`example/backend/`](example/backend/) | A runnable sandbox checkout on Android, iOS and web, and the reference merchant backend it talks to. |

## Support

- **A bug in this SDK** — open an issue at
  <https://github.com/uqpay/uqpay-sdk-flutter/issues> with the package
  version, Flutter version, platform and OS version, the `UqpayError` `code`,
  `developerMessage` and `traceId`, and steps to reproduce. Never paste a
  token, API key or card number.
- **A security vulnerability** — never a public issue; see
  [SECURITY.md](SECURITY.md).
- **Your UQPAY account, a payment, or credentials** — UQPAY support, quoting
  the `x-trace-id` of the failing request.

## License

MIT — see [LICENSE](LICENSE).
