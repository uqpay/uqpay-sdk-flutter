# Integration guide

The long form of the [README](../README.md). Read the README quickstart first;
this page is what you reach for when you wire the payment into a real app
with a real backend.

- [The shape of an integration](#the-shape-of-an-integration)
- [The backend contract](#the-backend-contract)
  - [`POST /client-token`](#post-client-token) · [`POST /payment-intents`](#post-payment-intents) · [`GET /payment-intents/{id}`](#get-payment-intentsid) · [`POST /webhooks/uqpay`](#post-webhooksuqpay)
- [Sandbox vs production](#sandbox-vs-production)
- [Web: CORS and origin setup](#web-cors-and-origin-setup)
- [Confirm on your server before fulfilling](#confirm-on-your-server-before-fulfilling)
- [Surviving process death](#surviving-process-death)
- [The 3-D Secure return URL](#the-3-d-secure-return-url)
- [Connect sub-accounts](#connect-sub-accounts)
- [Unit testing your checkout](#unit-testing-your-checkout)

Before going live, work through the
[security checklist](../README.md#security-checklist-for-production) in the
README. This guide shows the server side of each item.

---

## The shape of an integration

```
┌─────────┐   1. create intent    ┌──────────────────┐   x-api-key   ┌───────┐
│   app   │ ────────────────────▶ │  your backend    │ ────────────▶ │ UQPAY │
│         │ ◀──────────────────── │                  │ ◀──────────── │       │
│         │   2. client token     └──────────────────┘               └───────┘
│         │                                ▲                              │
│  sheet  │   3. the payment itself        │      4. webhook (a hint)     │
│         │ ───────────────────────────────┼──────────────────────────────┘
└─────────┘                   5. GET the intent — what you fulfil from
```

Four responsibilities, and only one of them is in the app:

1. **Your backend creates the payment intent.** It holds the API key; the app
   never does. Your server decides the amount, currency and customer from its
   own order record. This is also where UQPAY Connect routing is decided —
   see [Connect sub-accounts](#connect-sub-accounts).
2. **Your backend mints the client auth token.** Short-lived, one active token
   per merchant. The app fetches it through `tokenProvider`, from an endpoint
   only your signed-in users can call.
3. **The app presents the sheet** (or drives the headless API). The result is
   a UX signal.
4. **Your backend confirms the outcome** by retrieving the intent from the
   UQPAY API — prompted by a webhook, by the app, or by a timer. That is what
   you fulfil from.

## The backend contract

Your app needs two endpoints on **your** server, plus a webhook receiver.
[`example/backend/`](../example/backend/) is a small Dart (`package:shelf`)
reference that implements all of them, with tests; its endpoint names are
used below. It is a demo: its endpoints are unauthenticated and it takes the
amount from the request, which a production server must not do.

Your server talks to one of two UQPAY hosts. Choose it from server
configuration and make sure it matches the `environment` the app was built
with — a sandbox token does not work against production:

| Environment | UQPAY API host |
|---|---|
| `sandbox` | `https://api-sandbox.uqpaytech.com` |
| `production` | `https://api.uqpay.com` |

The UQPAY calls behind your endpoints, all on that host:

| Call | Purpose |
|---|---|
| `POST /api/v1/connect/token` | Mint the auth token. Headers `x-client-id` and `x-api-key`; **no body**. Response `{"auth_token":"…","expired_at":<epoch seconds>}`. |
| `POST /api/v2/payment_intents/create` | Create an intent. Headers and body below. |
| `GET /api/v2/payment_intents/{id}` | Retrieve an intent — the server-side truth you fulfil from. |

The payment-intent calls authenticate with `x-auth-token: Bearer <token>`
(a custom header, not `Authorization`), plus `x-client-id`. The SDK sends
`x-auth-token` from the app for `GET …/{id}`, `POST …/{id}/confirm` and
`POST …/{id}/cancel`, and `x-client-id` only when you pass `clientId` to
`UqpaySdk.init`. `clientId` is optional: the sandbox accepts confirms
without it; send it when your backend returns it. The `create`
call and the token mint are server-only.

### `POST /client-token`

Returns the current server token. The reference backend answers
`{"token":"…","expires_at":"<ISO-8601>","auth_token":"…","expired_at":<epoch s>,"client_id":"…"}`;
`auth_token` and `expired_at` mirror UQPAY's own shape, and
`UqpayAuthToken.fromJson` reads exactly those. `client_id` is what the app
may pass as `clientId`:

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

final uqpay = UqpaySdk.init(
  environment: UqpayEnvironment.sandbox,
  clientId: 'YOUR_UQPAY_CLIENT_ID', // optional; identifies the merchant, not a secret
  tokenProvider: () async {
    final response = await http.post(
      Uri.parse('$myBackend/client-token'),
      headers: {'authorization': 'Bearer ${await mySession.token()}'},
    );
    if (response.statusCode != 200) {
      throw StateError('token endpoint answered ${response.statusCode}');
    }
    return UqpayAuthToken.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    );
  },
);
```

A thrown error surfaces as `Failed` / `authentication_failed`, never a crash.

**Token lifetime and the one-token rule.** A UQPAY token lives about 30
minutes. UQPAY issues **one active token per merchant**: minting a new one
silently invalidates the previous one. If every device minted its own token,
each new device would log out every other device *and your own server*. So:

- Mint on the server, once, and cache the token.
- Refresh about two minutes before `expired_at`, and on any 401.
- Single-flight the mint: concurrent requests share one in-flight refresh.
- Run one backend per merchant. A colleague's second backend (or the native
  demo apps) against the same client id invalidates yours mid-flow; the SDK
  then resolves `Pending` with `authentication_failed`, which is the correct
  money-safe answer.

The SDK caches the token it receives until shortly before `expiresAt`,
de-duplicates concurrent `tokenProvider` calls, and calls it exactly once
more when the API answers 401. Always forward `expired_at`: without it the
SDK assumes a 20-minute lifetime and asks more often than it needs to.

**The token is the merchant's full-scope credential.** It is not scoped to
one payment: it is the merchant's single access token, and this endpoint
hands it to a device, where it can be extracted and used against other
UQPAY merchant APIs until it expires or is re-minted. Require your own
authenticated user session, rate-limit it per user, never make it callable
anonymously, and never log the token. Ask UQPAY for a scoped, intent-level
credential — see [What the auth token can do](../README.md#what-the-auth-token-can-do).

### `POST /payment-intents`

Creates the intent and returns its id. Three rules:

- **Amount, currency and customer come from your database, not from the
  request body.** The app sends an order or cart reference.
- **Send a lowercase UUID v4 `x-idempotency-key`** and reuse the same key,
  with the same bytes, on a retry of the same logical order.
- **Only your server calls UQPAY's create endpoint.** The app never creates
  an intent.

Behind it, `POST {host}/api/v2/payment_intents/create` with `x-client-id`,
`x-auth-token: Bearer <token>`, `x-idempotency-key`,
`Content-Type: application/json` and, for a Connect sub-account,
`x-on-behalf-of`. Body fields:

| Field | Notes |
|---|---|
| `amount` | Decimal **string** in major units: `"8.98"` is eight dollars ninety-eight. Never cents, never a JSON number. The reference backend forwards the string byte-for-byte and rejects a number with `400 invalid_amount`, because `8.90` re-serialised becomes `8.9`. `"898"` for JPY and `"8.980"` for BHD — nothing is multiplied or divided by 100 anywhere. |
| `currency` | ISO 4217, e.g. `"SGD"`. |
| `merchant_order_id` | Your order reference. Required upstream; the reference backend mints a UUID when omitted. |
| `description` | **Required, maximum 32 characters.** Measured against sandbox: 32 → 200, 33 → 400 with a bare `invalid_parameter` that does not name the field. The reference backend checks first and answers `400 invalid_description`. |
| `return_url` | Where a 3-D Secure or wallet redirect returns to. Must equal the `returnUrl` you pass to the SDK. See [The 3-D Secure return URL](#the-3-d-secure-return-url). |
| `metadata`, `payment_orders` | Optional; passed through. |

The response is UQPAY's intent object; its id is `payment_intent_id` and its
status `intent_status`. Return the id to the app. The app then passes it
straight to `UqpayPaymentSheet.present` or `uqpay.payments.confirm`.

### `GET /payment-intents/{id}`

Proxied to `GET /api/v2/payment_intents/{id}`. Your fulfilment logic reads
this, not the app's result. Watch `intent_status` (`SUCCEEDED`, or
`REQUIRES_CAPTURE` for an authorised intent you still have to capture) and
`latest_payment_attempt`.

### `POST /webhooks/uqpay`

Receives UQPAY webhooks. Register the public URL in the sandbox dashboard. The
reference backend logs `type / intent id / status`, keeps the last 50 in
memory and serves them at `GET /webhooks/recent` so the example app can show
a 3-D Secure outcome arriving at the server.

**UQPAY has not yet published a webhook signature scheme for this
integration.** The reference handler does no signature verification. Until a
scheme is published, treat a webhook as a *hint*: on receipt, `GET` the
intent from the UQPAY API and act on that. Never fulfil from the webhook body
alone. Re-check UQPAY's webhook documentation before going live.

## Sandbox vs production

Choose the environment from **explicit per-build configuration** — a
`--dart-define` (or `--dart-define-from-file`), a flavour, or a generated
config — never from `kDebugMode` or `kReleaseMode`. A release-mode build is
what your QA and internal testers run, so `kReleaseMode ? production :
sandbox` quietly points those builds at production: testers make real
charges and your production backend sees test traffic.

```dart
const _env = String.fromEnvironment('UQPAY_ENVIRONMENT', defaultValue: 'sandbox');

final uqpay = UqpaySdk.init(
  environment: _env == 'production'
      ? UqpayEnvironment.production
      : UqpayEnvironment.sandbox,
  tokenProvider: fetchToken,
);
```

```sh
flutter build apk --dart-define=UQPAY_ENVIRONMENT=production
```

Your server's UQPAY host and credentials must match what the app is built
for: a sandbox token against production fails with `authentication_failed`.
Sandbox and production credentials are separate and not interchangeable.

Two things make a wrong choice visible:

- The sheet draws a **"TEST MODE — no real money will move"** banner whenever
  the SDK was initialised with `UqpayEnvironment.sandbox`. No flag or
  `UqpayAppearance` setting turns it off, and it never appears in
  production. If a build you meant for
  customers shows it, the environment wiring is wrong.
- `UqpaySdk.init` takes an optional `baseUrlOverride`. It must be a bare
  `https` origin and should be unset in production builds; a test can assert
  `uqpay.usesCustomBaseUrl == false`.

Before you switch, re-read [sandbox testing](../README.md#sandbox-testing):
the one 3DS-enrolled test card, the one-token rule, and above all that
**sandbox QR wallets settle on real rails**.

## Web: CORS and origin setup

> **Confirm your origin with UQPAY before you ship a web checkout.** A
> browser sends the SDK's requests only if the UQPAY API
> (`https://api-sandbox.uqpaytech.com` or `https://api.uqpay.com`) answers the
> CORS pre-flight for your web origin. If it does not, every SDK call from a
> web build fails. Ask UQPAY support to confirm your origin is enabled, then
> run the check below. Android and iOS are unaffected: CORS is a browser
> rule.

On web the SDK calls the UQPAY API directly from the browser with `fetch`.
Every request carries non-simple headers, so the browser first sends a CORS
pre-flight (`OPTIONS`) to the API origin. The SDK sends:

| Header | When |
|---|---|
| `x-auth-token` | Every request (`Bearer <token>`). |
| `content-type: application/json` | Requests with a body (confirm, cancel). |
| `accept: application/json` | Every request. |
| `x-idempotency-key` | Confirm and cancel. |
| `x-client-id` | When you pass `clientId` to `UqpaySdk.init`. |
| `x-on-behalf-of` | When you pass `onBehalfOf` to `UqpaySdk.init`. |

The methods are `GET` (retrieve) and `POST` (confirm, cancel) on
`/api/v2/payment_intents/...`.

**What to verify before you ship a web checkout.** From your real web origin
(not `localhost` only), check in the browser's network tab — or with `curl -X
OPTIONS` carrying `Origin`, `Access-Control-Request-Method: POST` and
`Access-Control-Request-Headers` — that the API's pre-flight:

- answers **2xx without requiring an auth token** (a pre-flight never
  carries one);
- returns `Access-Control-Allow-Origin` matching your origin (or `*`);
- returns `Access-Control-Allow-Methods` including `GET` and `POST`;
- returns `Access-Control-Allow-Headers` covering `x-auth-token`,
  `x-idempotency-key`, `content-type`, `x-client-id` and `x-on-behalf-of`.

Then make one real sandbox call from that origin. Which origins the API
accepts is configured by UQPAY, not by this SDK; confirm with UQPAY support
that your production origin is enabled.

**What a CORS failure looks like.** The browser hides the reason from page
code: the SDK sees an opaque failed `fetch` and reports `network_error`
(retryable, outcome unknown — see [ERROR_CODES.md](../ERROR_CODES.md)). The
browser console shows the actual CORS message.

**No SDK setting can work around it.** CORS is enforced by the browser
against the API server's own answers; nothing the SDK sends changes them.
`baseUrlOverride` exists for a non-standard UQPAY deployment. Pointing it at
a proxy of your own is not a supported configuration: the customer's card
and wallet data and the auth token would pass through your server (which
brings it into PCI scope), and the SDK is not tested that way. Do not ship a
web checkout until the pre-flight check above passes and UQPAY confirms CORS
is enabled.

## Confirm on your server before fulfilling

The result your app receives is the device's last look at the payment. It is
the right thing to show the customer and the wrong thing to release goods on.

Between the gateway accepting the payment and your `switch` running, the
device can lose its network, be killed by the OS, or be a modified build
talking to your API — a rooted device can make your Dart code see
`UqpayPaymentCompleted` for a payment that never happened. None of that can
happen to your server.

So:

- **Fulfil only after your server has retrieved the intent** from the UQPAY
  API and seen a paid status.
- Treat `UqpayPaymentCompleted` as "show the receipt screen", not "ship the
  order".
- Treat `UqpayPaymentPending` as "we do not know yet" — never a failure,
  never a success, never a reason to charge again.
- Treat `UqpayPaymentFailed` with `error.isOutcomeUnknown == true` the same
  way as `Pending`.
- **Manual capture:** `Completed` with `status == requiresCapture` is
  authorised, not captured. Decide on capture from the intent your server
  retrieves.
- **A webhook is a prompt to re-fetch**, not proof — see
  [`POST /webhooks/uqpay`](#post-webhooksuqpay).

A practical shape: the app shows an optimistic receipt, then polls your own
order record, which your server updates after retrieving the intent.

## Surviving process death

A payment can be interrupted at any point: the OS kills the app during a
3-D Secure challenge, the customer force-quits, the browser tab reloads. The
SDK is built so that no interruption can cause a second charge, and so that
the interrupted payment can be resolved afterwards.

**Idempotency.** Before a confirm leaves the device the SDK persists a pin —
a lowercase UUID v4 `x-idempotency-key`, the intent id and a fingerprint of
the request — to `shared_preferences` (`localStorage` on web), namespaced by
environment and merchant. A lost response is replayed with the same key and a
byte-identical body (after 3, 6 and 10 s); a retry after a retryable failure
reuses the same pin. Pins are released when the intent resolves and expire
after 24 hours. No card data is stored in the pin: the fingerprint is a
one-way 64-bit hash of the request with the card number cut to its first
six and last four digits and the CVC removed (see
[PRIVACY.md](../PRIVACY.md#what-the-sdk-stores-at-rest)).

**On every launch**, after `init` and before you offer a new payment:

```dart
final results = await uqpay.payments.reconcileUnresolved();
for (final result in results) {
  switch (result) {
    case UqpayPaymentCompleted(:final intentId):
      // Paid on a previous run. Show the receipt; your server fulfils.
      showReceipt(intentId);
    case UqpayPaymentFailed() || UqpayPaymentCanceled():
      // Final; let the customer try again with a NEW intent.
      offerNewPayment(result.intentId);
    case UqpayPaymentPending(:final intentId):
      // Still in flight on the server. Keep showing "processing".
      showProcessing(intentId);
  }
}
```

Every case has a statement on purpose: in Dart 3 an empty `case` falls
through to the next one, so a case holding only a comment would run the
next case's code.

**Match the intent before you act.** Before acting on any result — from
`reconcileUnresolved()`, `reconcile()` or `UqpayReturnHandler.consume` — check
that `result.intentId` belongs to an order of yours (and, on a return, to the
order this session was paying). A crafted return URL can name any intent id,
so a result for an id you do not recognise must not update your UI or your
order state.

`reconcileUnresolved()` reads every unexpired pin in this environment,
`GET`s each intent once and maps the server's status to a result. Use
`unresolvedIntentIds()` if you only want the ids.

**A `Pending` in the same session** carries `reconcile()`, which does one
`GET` and maps the result. Call it when the customer returns to the order
screen, or on a timer. The other source is your own order record, which your
server updates after it retrieves the intent (a webhook is the prompt).

**Web page reloads.** A full-page 3-D Secure redirect unloads your app. The
SDK persists the in-flight intent id under `uqpay.redirect.pending` in
`localStorage` before redirecting; `UqpayReturnHandler.consume(Uri.base)` at
startup reads it (or the `uqpay_intent` query parameter), clears it, and
reconciles. See the next section.

**Dismissals.** `flow.cancel()` or closing the sheet before the confirm has
left the device yields `Canceled`; after, `Pending`. A payment in flight is
never reported as cancelled.

## The 3-D Secure return URL

`returnUrl` is the `return_url` registered on the intent. The SDK uses it
only to recognise the end of a challenge; its query string is never read for
a payment status. Put no secret, token or order data in it.

**Android and iOS.** The challenge opens in an in-app webview
(`UqpayWebviewChallengePresenter` → `UqpayChallengePage`). The webview's
navigation delegate ends the step when a navigation matches the return URL
(scheme, host and path prefix) or uses any non-web scheme, such as an app
scheme return or a banking-app deep link. The return never reaches the OS,
so **no `CFBundleURLTypes` entry and no Android intent filter are needed**.
`myapp://payment-return` works as-is. The flow then re-queries the intent
and maps the server's status; the challenge page's own outcome is only a
signal.

The challenge page times out after 10 minutes; the window restarts each time
the app returns to the foreground, so a long approval in a banking app cannot
by itself time the challenge out. A timeout is also only a signal —
the flow reconciles afterwards.

**Web.** Web has no card form in this version, so the sheet never runs a
card challenge in a browser. A redirect happens on web only when a
redirect-based (non-card) method answers the confirm with a
`redirect_to_url` next action, or when your own headless code confirms a
card on web; QR and bank-transfer methods render in the sheet. Only
`redirect_to_url` is supported on web in this version: a `redirect_iframe`
next action is reported by `UqpayRedirectChallengePresenter` as an
`invalid_configuration` failure, not navigated to. A redirect is a full page in the same tab, so `return_url`
must be an `https` page of your web app (a `myapp://` scheme works only on
Android and iOS). Two channels bring the intent id back:

- the `uqpay_intent=<intent_id>` query parameter, if your backend can
  template `return_url` per intent — build it with
  `UqpayReturnHandler.returnUrlFor(returnUrl, intentId)`;
- the `localStorage` slot the SDK writes before redirecting, which survives
  even when the bank strips query parameters.

At startup:

```dart
final handler = UqpayReturnHandler(payments: uqpay.payments);
final result = await handler.consume(Uri.base);
if (result != null) {
  // The customer came back from a challenge. Show the result; your server
  // fulfils.
}
```

`consume` returns `null` when the app was not opened by a challenge return,
never throws, and reads nothing from the URL except the intent id. Match
`result.intentId` to your own order before acting on it (see
[Surviving process death](#surviving-process-death)). A browser
back/forward replay costs at most one `GET`, never a confirm.

**Your own presenter.** Implement `UqpayChallengePresenter` to show the
challenge another way — a Custom Tab, an external browser, your own
webview — and pass it as `challengePresenter` to the sheet or `createFlow`.
It must not throw (report problems as `UqpayChallengeOutcome.failed`), must
never read the challenge page's content, and must never trust the return
URL's query string.

## Connect sub-accounts

UQPAY Connect platforms act on behalf of connected sub-accounts with the
`x-on-behalf-of` header. Set it in both places:

- **On your backend**, when creating the intent (`x-on-behalf-of` on
  `POST /api/v2/payment_intents/create`). The reference backend reads
  `UQPAY_ON_BEHALF_OF` for this.
- **In the app**, with `UqpaySdk.init(onBehalfOf: subAccountId)`. The SDK
  then sends `x-on-behalf-of` on every request — retrieve, confirm, cancel.
  An empty string throws `ArgumentError`; omit the parameter for direct
  accounts.

The sub-account id is an identifier, not a secret, but which sub-account a
given order belongs to is a server decision. Hand the app the id together
with the intent id from the same backend call so the two cannot disagree.

## Unit testing your checkout

You do not need a network, a simulator or sandbox credentials to test how
your app reacts to each outcome.

**Construct results directly.** Every `UqpayPaymentResult` case has a public
constructor, and `UqpayPaymentIntent.fromJson` accepts the wire shape, so
your `switch` can be tested with fixtures:

```dart
final paid = UqpayPaymentCompleted(
  intent: UqpayPaymentIntent.fromJson(const {
    'payment_intent_id': 'pi_123',
    'intent_status': 'SUCCEEDED',
    'amount': '8.98',
    'currency': 'SGD',
  }),
);

const declined = UqpayPaymentFailed(
  intentId: 'pi_123',
  error: UqpayError(
    code: UqpayErrorCode.cardDeclined,
    developerMessage: 'issuer declined',
    userMessage: 'Your card was declined.',
    isRetryable: false,
  ),
);

final pending = UqpayPaymentPending(
  intentId: 'pi_123',
  lastKnownStatus: UqpayIntentStatus.processing,
  reconcile: () async => paid,
);
```

Put the sheet call behind your own small interface (`Future<UqpayPaymentResult>
pay(String intentId)`) and fake that in widget tests. The sealed switch in
your handler then compiles against the real types and runs without I/O.

Do not fake the SDK by implementing or extending `UqpayPayments`,
`UqpayPaymentFlow` or `UqpayPaymentSheet`. They are not designed for it, and
[STABILITY.md](../STABILITY.md#which-types-you-may-implement-or-extend) gives
no guarantee for such fakes: a minor release may add members they do not
override.

**Time.** `UqpayClock` is public. `UqpayPaymentSheet(clock:)`,
`UqpayPaymentSheet.present(clock:)` and `UqpayChallengePage(clock:)` take
one, so QR countdowns and challenge timeouts can be driven from a fake in a
widget test instead of waiting in real time. `UqpayPaymentSheet(isWebPlatform:)`
is a test-only override of the web detection (`@visibleForTesting`).

**Deeper: the SDK's own seam.** `UqpayPayments.withDependencies(sdk:,
httpClient:, clock:, storage:, pollingPolicy:)` is how the SDK's own suite
wires a `UqpayPayments` over a scripted HTTP client, an injectable clock and
an in-memory pin store. It is `@visibleForTesting`, and its parameter types
(`UqpayHttpClient`, `KeyValueStore`, `PollingPolicy`) live under `lib/src/`,
outside the public API that [STABILITY.md](../STABILITY.md) covers. Treat it
as a reference pattern for contributors, not a merchant-facing contract. The
fakes are in [`test/support/fakes.dart`](../test/support/fakes.dart):

| Helper | What it is |
|---|---|
| `FakeClock` | Time moves only when the test says; delays complete immediately and are recorded. |
| `ManualClock` | Delays stay pending until `advance()` reaches them; `pendingTimers` counts live timers for leak tests. |
| `FakeHttpClient` | Scripted responses (`enqueue`, `enqueueHandler`, `enqueueError`); records every request for header assertions. |
| `PaymentsHarness` | A `UqpayPayments` over all of the above with jitter-free polling; `confirms` and `reads` list the requests sent. |
| `jsonResponse`, `intentJson`, `failedAttempt`, `qrNextAction`, `redirectNextAction` | Wire-shaped fixtures. |
| `cardConfirmRequest`, `walletConfirmRequest`, `browserInfo`, `sdkWithTokens` | A complete card/wallet confirm request, a frozen device snapshot, and an SDK handle whose token provider hands out a scripted list of tokens. |
