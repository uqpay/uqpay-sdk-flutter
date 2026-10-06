# uqpay_sdk_flutter — sample app

A working checkout you can run against the UQPAY **sandbox** on Android, iOS
and Chrome after one config change. It exercises both API surfaces (the
drop-in sheet and the headless `UqpayPayments` calls), theming, the full error
contract, and the pending/reconcile path.

It depends on the SDK by relative path (`../`), so it always exercises the
working tree, and it is the fixture CI builds for Android, iOS, web (JS) and
web (Wasm).

> A real sandbox payment needs credentials **you** supply — a sandbox
> `UQPAY_CLIENT_ID` and `UQPAY_API_KEY` from
> <https://app-sandbox.uqpaytech.com> → Developer → API Keys, and a sandbox
> test card from the same dashboard. Nothing in this repository contains or
> ships credentials, and the app never sees the API key at all.

---

## Runbook

A few commands from a clean clone of the
[GitHub repository](https://github.com/uqpay/uqpay-sdk-flutter). Budget ten
minutes.

### 1. Configure

```sh
# from the repo root
cp env.template .env
```

Fill in `.env`:

| Key | Who reads it | Value |
|---|---|---|
| `UQPAY_CLIENT_ID` | backend only | from the sandbox dashboard |
| `UQPAY_API_KEY` | backend only | from the sandbox dashboard, shown once |
| `UQPAY_ENVIRONMENT` | app + backend | `sandbox` |
| `UQPAY_MERCHANT_BACKEND_URL` | app | `http://localhost:8787` |
| `UQPAY_ON_BEHALF_OF` | app + backend | blank unless you use UQPAY Connect |
| `UQPAY_WEBHOOK_URL` | backend only | blank until you expose a tunnel |

`.env` is gitignored and belongs to the **backend**. The app gets its own
file, `example/app.env` (also gitignored), generated from `.env` with only
the three app keys — `UQPAY_ENVIRONMENT`, `UQPAY_MERCHANT_BACKEND_URL`,
`UQPAY_ON_BEHALF_OF`:

```sh
cd example
tool/app_env.sh      # re-run whenever you edit ../.env
```

**Never pass the API key as a `--dart-define`**, and never point
`--dart-define-from-file` at the root `.env`: every define is written into
generated build files and can be compiled into the app. The SDK has no
parameter that accepts an API key, and a test in `test/config_test.dart`
fails the build if the app ever reads one.

### 2. Start the merchant backend

```sh
cd example/backend
dart pub get
tool/run.sh          # sources ../../.env, listens on http://localhost:8787
```

This is the piece you replace with your own server. It holds the API key,
mints and caches the auth token, creates payment intents and receives
webhooks. See `example/backend/README.md`.

### 3. Run the app

From `example/`:

```sh
flutter pub get

# Android or iOS: list devices, then pass one id
# (an emulator id such as emulator-5554, or a simulator UDID)
flutter devices
flutter run -d <device-id> --dart-define-from-file=app.env

# Web
flutter run -d chrome --dart-define-from-file=app.env
flutter run -d chrome --wasm --dart-define-from-file=app.env   # Wasm build
```

> **Android emulator / physical device:** `localhost` is the device, not your
> Mac. Set `UQPAY_MERCHANT_BACKEND_URL=http://10.0.2.2:8787` in `.env` for
> the Android emulator, or your machine's LAN IP for a physical device, re-run
> `tool/app_env.sh` and rerun the app (or keep `localhost` and run
> `adb reverse tcp:8787 tcp:8787`). The app tells you this on screen when it
> cannot reach the backend.

### 4. Pay

Enter an amount, pick a currency, press **Pay with the sheet**. Then do the
same on the **Headless checkout** screen and compare.

### Sandbox test cards

These are the UQPAY sandbox test cards (same table as the package README).
Any name on card and
(on the headless screen) the prefilled billing address work.

| Card number | Expiry | CVC | Behaviour |
|---|---|---|---|
| `6250947000000014` (UnionPay) | `12/33` | `123` | No 3-D Secure; `Completed`, intent `SUCCEEDED`. Use it for the success path. |
| `5521970079998012` (Mastercard, 3DS) | `10/28` | `001` | The only 3DS-enrolled card: the challenge opens and authenticates, then `Completed`, intent `SUCCEEDED`. Use it for the 3-D Secure success path. |
| `5413330057004047` (Mastercard) | `12/30` | `989` | 3-D Secure fails: `Failed` / `3ds_failed`. |
| any Visa number | — | — | `Failed` with the server's `system_error`. |

---

## The ≤25 lines this app boils down to

Everything the sample does around the payment is scaffolding. The integration
itself is this:

```dart
final uqpay = UqpaySdk.init(
  environment: UqpayEnvironment.sandbox,
  tokenProvider: () async {
    final response = await http.post(Uri.parse('$backend/client-token'));
    return UqpayAuthToken.fromJson(jsonDecode(response.body) as Map<String, Object?>);
  },
);

// Your backend creates the intent and returns its id.
final intentId = await myBackend.createPaymentIntent(amount: '8.98', currency: 'USD');

final result = await UqpayPaymentSheet.present(
  context,
  payments: uqpay.payments,
  intentId: intentId,
  returnUrl: Uri.parse('myapp://payment-return'),
);

switch (result) {
  case UqpayPaymentCompleted():
    showReceipt(); // your server fulfils after it retrieves the intent
  case UqpayPaymentFailed(:final error):
    showError(error.userMessage, retryable: error.isRetryable);
  case UqpayPaymentCanceled():
    backToCheckout(); // nothing was charged
  case UqpayPaymentPending(:final intentId):
    showProcessing(intentId); // reconcile later, never re-charge
}
```

---

## Screens

| Screen | What it shows |
|---|---|
| **Home** | The resolved configuration (environment, API origin, backend URL, `x-client-id`, `return_url`, platform), a sandbox/production switch, backend reachability, the order (amount + currency + description), the two API surfaces, the last result, and a startup list of unresolved payments. |
| **Headless checkout** | `retrieveIntent` → `createFlow` → `confirm` driven by the app's own UI, with the progress stream, `next_action`, and `cancel` / `pause` / `resume` buttons. Card form on mobile; wallet / QR / redirect only on web. |
| **Webhooks** | Polls `GET /webhooks/recent` every three seconds so you can watch UQPAY's webhook arrive at the server. A webhook is a hint: the server re-reads the intent before it fulfils. |

### Theming

The app-bar has two toggles:

* **brightness** — cycles system → light → dark. The sheet follows the host
  `ThemeMode` and never forces its own brightness.
* **palette** — turns on a custom `UqpayAppearance` (orange scheme, 4 px
  corners, restyled pay button) while the host app stays blue, so the effect
  of the override is unmistakable.

### Web has no card entry — on purpose

Card fields rendered inside the merchant's own origin typically move a
merchant from PCI **SAQ A** to **SAQ A-EP**. Card entry is therefore simply
unavailable on web in this version: the sheet offers the intent's wallet, QR
and redirect methods only. The sheet and the headless screen both say so on
screen when running in a browser.

Desktop is not configured here at all: the SDK supports Android, iOS and web,
and `UqpaySdk.init` throws an `UnsupportedError` naming the platform anywhere
else.

---

## What this example demonstrates

On Android, iOS and web, the app shows each part of a production
integration: a sandbox payment through the drop-in sheet and through the
headless API, a 3-D Secure challenge, user cancellation before confirm,
`Pending` results that are reconciled from the server (after a lost network,
an app kill or a web reload), QR expiry, currencies with zero and three
decimal places sent as exact decimal strings, theming that follows the host
app, the sandbox/production switch, and the difference between
`flow.cancel()` (nothing sent) and `payments.cancelIntent()` (cancels the
intent on the server).

### The webhook screen

The client result is a **UX signal, not proof of payment**. Your server
fulfils only after it retrieves the intent from the UQPAY API; a webhook is
the prompt to do that, not proof on its own. To see deliveries in the
webhook screen, expose
`example/backend` publicly (a tunnel is enough), register that URL for
`POST /webhooks/uqpay` in the sandbox dashboard and put it in
`UQPAY_WEBHOOK_URL`. Without that the list stays empty and that is expected.

---

## Test

```sh
cd example
flutter test
```

The suite covers configuration resolution, the unreachable-backend message,
the amount-in-major-units contract and the four-way result renderer against a
faked backend — no network, no credentials.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Cannot reach the merchant backend" | the backend is not running, or the URL is wrong for this device | start `example/backend/tool/run.sh`; on an Android emulator use `http://10.0.2.2:8787` |
| The backend refuses to start | `UQPAY_CLIENT_ID` or `UQPAY_API_KEY` is missing | fill them in `.env`; the backend names the missing variable |
| `token_issue_failed` | sandbox credentials rejected, or production credentials used against sandbox | sandbox and production credentials are separate and not interchangeable |
| `authentication_failed` on every call | another process minted a token for the same merchant | UQPAY allows one active token per merchant; run one backend |
| The web build shows no card option | by design — see "Web has no card entry" above | test cards on Android or iOS |
| Webhook screen stays empty | UQPAY cannot reach your backend | expose it with a tunnel and register the URL |
