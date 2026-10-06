# Troubleshooting

Symptom → cause → fix, for the failure modes seen most often while
integrating. If your symptom is not here, check
[Limitations](../README.md#limitations) and
[ERROR_CODES.md](../ERROR_CODES.md) — every `UqpayError` has a `code`, a
`developerMessage` and a `traceId` to quote to UQPAY support.

- [`authentication_failed` on every call](#authentication_failed-on-every-call)
- [`token_issue_failed` from the reference backend](#token_issue_failed-from-the-reference-backend)
- [`invalid_payment_method`: "invalid card network"](#invalid_payment_method-invalid-card-network)
- [`invalid_payment_method`: "invalid billing.email" / "invalid billing.address…"](#invalid_payment_method-invalid-billingemail--invalid-billingaddress)
- [The sheet sits on "Waiting for confirmation" after 3-D Secure](#the-sheet-sits-on-waiting-for-confirmation-after-3-d-secure)
- [The customer closed the 3-D Secure page](#the-customer-closed-the-3-d-secure-page)
- [The web build shows no card option](#the-web-build-shows-no-card-option)
- [Android emulator cannot reach the backend on `localhost`](#android-emulator-cannot-reach-the-backend-on-localhost)
- [iOS physical device cannot reach an `http://` backend](#ios-physical-device-cannot-reach-an-http-backend)
- [Intent creation fails with `invalid_parameter`](#intent-creation-fails-with-invalid_parameter)
- [`UnsupportedError` on desktop](#unsupportederror-on-desktop)
- [`present` returns `Failed` / `invalid_configuration` immediately](#present-returns-failed--invalid_configuration-immediately)
- [`ArgumentError` naming `tokenProvider`](#argumenterror-naming-tokenprovider)
- [The sheet shows "TEST MODE" in a build I meant for customers](#the-sheet-shows-test-mode-in-a-build-i-meant-for-customers)
- [`flutter pub get` fails with a version conflict](#flutter-pub-get-fails-with-a-version-conflict)
- [Web: every call fails with `network_error` (CORS)](#web-every-call-fails-with-network_error-cors)
- [Obfuscated release builds](#obfuscated-release-builds)
- [Add-to-app or nested `Navigator`: the sheet opens on the wrong navigator](#add-to-app-or-nested-navigator-the-sheet-opens-on-the-wrong-navigator)

---

## `authentication_failed` on every call

**Symptom.** Every payment resolves `Failed` with `authentication_failed`,
or a running payment suddenly resolves `Pending` with
`authentication_failed` as the cause. The SDK already retried once with a
fresh token.

**Causes, in order of likelihood.**

1. **Someone else minted a token.** UQPAY allows **one active token per
   merchant**. A colleague running a second copy of the backend, the native
   iOS/Android demo apps, or a CI job against the same client id invalidates
   yours. Each side then invalidates the other on refresh.
2. Your `tokenProvider` threw, returned an empty `auth_token`, or your
   backend is unreachable from the device (see the emulator and iOS entries
   below).
3. Environment mismatch: a sandbox token against `UqpayEnvironment.production`
   or the reverse. Credentials are not interchangeable.

**Fix.** Run exactly one backend per merchant and coordinate before starting
a second. Log inside your `tokenProvider` — the HTTP status and whether
`auth_token` was non-empty, never the token itself — and check your backend's
`/health` from the device, not from your laptop. Turn on
`UqpaySdk.init(loggingEnabled: true)` to see the 401 and its `x-trace-id`.

## `token_issue_failed` from the reference backend

**Symptom.** `example/backend` answers `/client-token` with
`token_issue_failed`, or logs it at startup.

**Cause.** UQPAY rejected the credentials at `POST /api/v1/connect/token`:
`UQPAY_CLIENT_ID` / `UQPAY_API_KEY` are wrong, or production credentials
were used against sandbox (or the reverse).

**Fix.** Re-create the key pair in the sandbox dashboard (Developer → API
Keys; the key is shown once) and put it in `.env`. Check
`UQPAY_ENVIRONMENT` matches the dashboard the key came from.

## `invalid_payment_method`: "invalid card network"

**Symptom.** A headless card confirm resolves `Failed` /
`invalid_payment_method` with a developer message about an invalid card
network, before any 3-D Secure step.

**Cause.** The gateway **requires** `payment_method.card.network`. Earlier
pre-release builds sent nothing when `UqpayCardDetails(network:)` was null;
the SDK now fills it from the PAN via `UqpayCardBrand.detect`. You still get
this error when the PAN matches no known BIN range (the SDK then sends no
`network` rather than inventing one), or when you passed an explicit value
the gateway does not accept.

**Fix.** Leave `network` null and let the SDK detect it. If you must pass it,
use `UqpayCardBrand.<brand>.wireName` — `visa`, `mastercard`, `amex`,
`discover`, `jcb`, `dinersclub`, `unionpay` — never the enum's `name`. Use
`UqpayCardBrand.detect(digits)` in your form to refuse PANs it cannot
classify.

## `invalid_payment_method`: "invalid billing.email" / "invalid billing.address…"

**Symptom.** A headless card confirm resolves `Failed` /
`invalid_payment_method` naming `billing.email`, `billing.address.country_code`,
`city`, `street`, `postcode` or `state`.

**Cause.** The gateway requires `billing.firstName`, `billing.lastName`,
`billing.email` and `billing.address.countryCode`, `city`, `street` and
`postcode` on every card
confirm, and `state` for some countries (US yes, SG no — the gateway
decides). An empty string is rejected the same as a missing field. The
drop-in sheet collects all of these; a headless integration has to.

**Fix.** Populate `UqpayBillingDetails` and `UqpayAddress` fully. Collect
`countryCode` from an explicit picker, never guess it from free text. The
SDK fills `first_name` / `last_name` from the cardholder name when you leave
them `null` (a single-word name is used for both), so "invalid
billing.last_name" means you passed an explicit empty string. Join
two street lines with `", "`.

## The sheet sits on "Waiting for confirmation" after 3-D Secure

**Symptom.** The customer completes (or fails) the 3-D Secure challenge, the
webview closes, and the sheet shows "Waiting for verification" or "Waiting
for confirmation" before resolving `Failed` or, after minutes, `Pending`.

**Cause.** The gateway left the intent in `REQUIRES_CUSTOMER_ACTION` after
the challenge instead of moving it to a terminal status. The SDK never
guesses from the challenge outcome: it reads the intent until the server
decides. Two cases:

- the latest attempt is **settled as failed** and no further action is
  served: the SDK resolves `Failed` with that attempt's code (for example
  `system_error`), at once;
- the attempt is **still in progress**: the SDK keeps polling with back-off
  until the outcome deadline (5 minutes of active waiting) passes, then
  resolves `Pending` rather than guess.

**What to do.** For `Pending`, show "processing", call `result.reconcile()`
later or `reconcileUnresolved()` on the next launch, and let your server's
view of the intent decide. If a `Failed` with `system_error` follows a
successful authentication, or this happens in production, contact UQPAY
support and quote the `x-trace-id`.

## The customer closed the 3-D Secure page

**Symptom.** The customer taps back or close on the verification page; the
sheet does not cancel, it keeps waiting.

**Cause.** By design. Closing the challenge UI is a signal, not a result: the
customer may have authenticated and *then* closed it. The flow re-queries
the intent and keeps polling.

**What to do.** Nothing — the result arrives from the server. If the
customer then closes the sheet, the result is `Pending` (the confirm has
left the device), never `Canceled`. Reconcile as usual.

## The web build shows no card option

**Symptom.** In Chrome the sheet lists wallets and QR methods only, with a
note that card entry is not available; `cardOnly()` shows "No payment
methods are available".

**Cause.** By design. Card fields rendered inside your own origin typically
move a merchant from PCI SAQ A to SAQ A-EP, so web v1 does not render the
card form. The sheet and the example's headless screen both say so on
screen.

**Fix.** Test cards on Android or iOS. On web, use the intent's wallet/QR
methods.

## Android emulator cannot reach the backend on `localhost`

**Symptom.** On the Android emulator the token fetch fails (connection
refused) and the example app says it cannot reach the merchant backend.

**Cause.** Inside the emulator `localhost` is the emulator itself, not your
machine.

**Fix.** Either address the host as `10.0.2.2`
(`UQPAY_MERCHANT_BACKEND_URL=http://10.0.2.2:8787`), or forward the port:

```sh
adb reverse tcp:8787 tcp:8787
```

after which `http://localhost:8787` works inside the emulator. A physical
Android device needs your machine's LAN IP. Plain `http://` to a local
backend works on Android debug builds; the SDK itself only ever talks
`https` to UQPAY.

## iOS physical device cannot reach an `http://` backend

**Symptom.** The simulator works with `http://localhost:8787`, but a physical
iPhone fails to fetch the token from `http://<your-mac-ip>:8787`.

**Cause.** App Transport Security blocks plain `http://` to a non-local
host. This concerns *your* backend URL; the SDK's own traffic to UQPAY is
always `https`.

**Fix.** Serve your backend over `https` (a tunnel is the quickest way). For
a **debug build only**, you can add `NSAppTransportSecurity` →
`NSAllowsLocalNetworking` to `Info.plist` to permit unencrypted local-network
connections. Never ship a release build with an ATS exception.

## Intent creation fails with `invalid_parameter`

**Symptom.** `POST /api/v2/payment_intents/create` answers 400
`invalid_parameter` without naming a field.

**Cause.** `description` is required and limited to **32 characters**; a longer
value is rejected. The reference backend validates this first
and answers `400 invalid_description` instead.

**Fix.** Truncate or shorten the description on your server. Also check
`amount` is a decimal *string* and `merchant_order_id` is present.

## `UnsupportedError` on desktop

**Symptom.** `UqpaySdk.init` throws "The UQPAY Flutter SDK does not support
macOS/Windows/Linux".

**Cause.** Desktop is out of scope. The SDK fails loudly at init rather than
half-working.

**Fix.** Call `init` only on Android, iOS and web — for example behind a
platform check in a shared codebase. There is no flag to bypass this.

## `present` returns `Failed` / `invalid_configuration` immediately

**Symptom.** A second call to `UqpayPaymentSheet.present` for the same intent
returns `UqpayPaymentFailed` with `invalid_configuration` without opening a
sheet. Typically from a double-tapped Pay button.

**Cause.** One sheet per intent. The second call is refused while the first
is still open.

**Fix.** Await the first result before presenting again, or disable the
button while a present is in flight.

## `ArgumentError` naming `tokenProvider`

**Symptom.** Accessing `uqpay.payments`, or the first API call, throws
`ArgumentError` naming `tokenProvider`.

**Cause.** `UqpaySdk.init` was called without a `tokenProvider`. That is
allowed while wiring up an app, but nothing can talk to the API without one.

**Fix.** Pass a `tokenProvider` to `init`. Programmer errors like this throw
at call time, by design, so they cannot surface mid-payment.

## The sheet shows "TEST MODE" in a build I meant for customers

**Symptom.** A "TEST MODE — no real money will move" banner at the top of the
sheet.

**Cause.** The SDK was initialised with `UqpayEnvironment.sandbox`. The
banner cannot be turned off by a flag or `UqpayAppearance` and never appears with
`UqpayEnvironment.production`.

**Fix.** Choose the environment from an explicit per-build setting and check
the value that reached `init` — see
[sandbox vs production](integration-guide.md#sandbox-vs-production). Make
sure your backend's `UQPAY_ENVIRONMENT` and credentials match.

## `flutter pub get` fails with a version conflict

**Symptom.** `pub get` reports "version solving failed" naming
`uqpay_sdk_flutter` and one of its dependencies.

**Cause.** Your app, or another package in it, needs a version outside one
of the SDK's ranges. The SDK's constraints (from its `pubspec.yaml`) are:

| Dependency | Constraint |
|---|---|
| Dart SDK | `^3.11.0` |
| Flutter | `>=3.41.0` |
| `http` | `^1.6.0` |
| `intl` | `^0.20.2` |
| `shared_preferences` | `^2.5.5` |
| `url_launcher` | `^6.3.2` |
| `webview_flutter` | `^4.14.1` |

**Fix.** Run `flutter --version`; anything older than Flutter 3.41 / Dart
3.11 cannot resolve and needs a Flutter upgrade. Otherwise run
`flutter pub deps` (or read the solver message) to see which package holds
the other side, and upgrade that package or your own constraint so the
ranges overlap. `intl` is the usual one: `flutter_localizations` pins an
exact `intl` per Flutter release (0.20.2 on Flutter 3.41), which is why the
SDK's floor is 0.20.2 — do not pin `intl` yourself to a different version.
Avoid `dependency_overrides` for these packages in a release build; an
override bypasses the ranges the SDK was tested against.

## Web: every call fails with `network_error` (CORS)

**Symptom.** On web only, every retrieve or confirm fails with
`network_error`; the browser console shows a CORS error on an `OPTIONS`
request to the UQPAY API. Android and iOS work.

**Cause.** The browser's CORS pre-flight to the UQPAY API did not succeed
for your origin. The API must answer the `OPTIONS` pre-flight with a 2xx and
the `Access-Control-*` headers; if it answers with an error (for example
401) or without those headers, the browser blocks every call. The browser
hides the reason from page code, so the SDK can only report a failed
`fetch`.

**Fix.** Nothing in the app or SDK configuration fixes this; the API must
answer the pre-flight. See
[Web: CORS and origin setup](integration-guide.md#web-cors-and-origin-setup)
for what to verify, and ask UQPAY support to confirm your origin is
enabled.

## Obfuscated release builds

**Symptom.** Concern that `flutter build ... --obfuscate
--split-debug-info=<dir>` changes what the SDK sends.

**Cause / fact.** Obfuscation renames classes and members, so anything
derived from `runtimeType` changes. No wire value in the SDK is derived from
`runtimeType` or an enum's `.name`: header names, paths, JSON keys and the
SDK's own enum-like wire values are string constants, and enum `.name` is
used only in error messages, `toString` and log lines.
`test/source_hygiene_test.dart` ("no wire value derived from runtimeType or
Enum.name") fails if `runtimeType` appears anywhere in `lib/src` other than the
model base class's `==` and `toString`.

**Fix.** None needed; obfuscated builds are supported. Keep the
`--split-debug-info` symbols for each release so you can de-obfuscate stack
traces with `flutter symbolize`. Model `toString()` output (which uses the
class name) will show obfuscated names in such builds; it is never sent to
the API. The SDK's CI does not build an obfuscated binary, so run your own
sandbox payment on an obfuscated build before release.

## Add-to-app or nested `Navigator`: the sheet opens on the wrong navigator

**Symptom.** In an add-to-app module, or inside a nested `Navigator` (tabs,
a side panel), the sheet or the 3-D Secure page appears above or below the
part of the UI you expected, or `present` throws because there is no
`Navigator` or `MaterialLocalizations` above the context.

**Cause.** `UqpayPaymentSheet.present(context, ...)` pushes the sheet onto
`Navigator.of(context, rootNavigator: useRootNavigator)`, and
`useRootNavigator` defaults to `true` — so by default the sheet covers the
**root** navigator of the Flutter view, not the nested one your `context`
sits in. The card 3-D Secure page is pushed onto the same navigator. In
add-to-app the root is the `Navigator` of the Flutter view (its
`MaterialApp`); the sheet cannot cover native host screens around that view.

**Fix.**

- Keep the default when the sheet must cover everything, including a nested
  navigator.
- Pass `useRootNavigator: false` to confine the sheet (and the 3-D Secure
  page) to the nearest `Navigator` above the `context` you pass.
- In add-to-app, call `present` with a `context` from inside the module's
  `MaterialApp`, or add `DefaultMaterialLocalizations.delegate` /
  `GlobalMaterialLocalizations.delegate` to the app's
  `localizationsDelegates` — otherwise `present` throws a `StateError`
  before showing anything.
- The embeddable `UqpayPaymentSheet` widget pushes its 3-D Secure page onto
  the nearest `Navigator` above where you place it.
