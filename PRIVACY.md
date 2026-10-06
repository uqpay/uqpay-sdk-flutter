# Privacy and data collection

**Release candidate `1.0.0-rc.1`.** This document is written for merchants
filling in Apple's App Privacy "nutrition label" and Google Play's Data Safety
form. It describes what `uqpay_sdk_flutter` itself collects, why, and whether
it leaves the device. It describes the code in this release and is updated
with each release. If anything here disagrees with the code,
the code is the bug.

## Summary

| Data | Collected? | Purpose | Leaves the device? | Stored on device? |
|---|---|---|---|---|
| Card number (PAN), expiry, CVC, cardholder name | Yes, when the user types it into a card form (or your app passes it to the headless API) | To create the payment | **Yes — to the configured UQPAY environment only, over HTTPS** | **No.** Only a non-reversible hash, in the idempotency pin (see below) |
| Device / browser snapshot for 3-D Secure risk (platform name, language tag, screen width and height, colour depth, time-zone offset, a random per-session device id, and the device's own network-interface IP address) | Yes, with every card or wallet confirm | Required by the card networks for the 3DS challenge and risk decision | Yes — to UQPAY, which forwards what the issuer needs | No (the device id is regenerated per sheet session and never written) |
| Payment intent identifiers and idempotency keys | Yes, generated per payment attempt | To recover an in-flight payment after an interruption and to prevent a duplicate charge | Yes — to UQPAY | **Yes**, temporarily (see below) |
| Merchant-supplied billing details (name, email, phone, address) | Only if your app passes them to the SDK, or the user types them into the card form | Required by the gateway for a card payment; the address is used for AVS | Yes — to UQPAY | No. Only as an input to the pin's hash (see below) |
| Analytics, crash reports, advertising identifiers, location, contacts | **No** | — | — | — |

The 3DS snapshot is best-effort risk data built from what Flutter itself can
see. A pure-Dart SDK has no native identifiers: the device id is a random
value per sheet session, the OS version is sent as `unknown`, the user agent
is a fixed SDK string, and location is never read. The IP address is the
address of an active network interface (a private address behind NAT); the
SDK never fabricates a public one, and omits the field when no interface can
be enumerated.

## What the SDK stores at rest

The **only** things the SDK writes to local storage (`shared_preferences` on
mobile, `localStorage` on web) are:

- **Idempotency pins**, under keys prefixed `uqpay.idem.`, so a retried
  request cannot produce a second charge. A pin holds the idempotency key
  the SDK generated for the attempt, the intent id, a timestamp, the device
  IP address the SDK sent with the confirm (only when the SDK resolved it
  itself, so a retry sends identical bytes), and a **fingerprint**. Pins are
  namespaced by environment, API origin and client id, are removed when the
  attempt resolves, and expire after 24 hours.

  The fingerprint is a 64-bit non-reversible hash (FNV-1a — a
  non-cryptographic hash) of the confirm request, computed after the card
  number is reduced to its **first six and last four digits**, the **CVC is
  removed** and the 3-D Secure browser/device snapshot is left out. It
  therefore depends on the card's first six and last four digits, the
  expiry, the cardholder name, the billing details and the rest of the
  request, but none of those values is stored and none can be read back from
  the hash. The full card number and the CVC are never inputs to it.
- **The in-flight intent id for a web redirect**, under
  `uqpay.redirect.pending`, written before a full-page 3-D Secure redirect
  and cleared when the app consumes the return.

Apart from that hash, no card data (card number, CVC, expiry, cardholder
name) and no billing detail is written to storage, cookies or files, on any
platform, and none is ever logged. A redaction test runs the full card
confirm through a capturing `debugPrint` and asserts it.

## Logging

Logging is off by default. When a merchant enables it
(`UqpaySdk.init(loggingEnabled: true)`), the SDK emits the HTTP method, path
and status code of each request, the `x-trace-id`, the intent id, flow phase
transitions and the class name of an unexpected exception — to the merchant's
`logHandler` or to `dart:developer`. It never emits a request or response
body, card data, billing details or a token. There is no "log this object"
entry point, so a future call site cannot add one by accident.

## What leaves the device

Every network request the SDK makes goes to the **UQPAY environment you
configured** (`https://api-sandbox.uqpaytech.com` or `https://api.uqpay.com`,
or an `https` origin you explicitly override). The SDK refuses non-HTTPS
origins at initialisation. The one exception is a wallet QR image: when the
API answers with a `qr_code_url`, the sheet downloads that image only if the
URL is `https` and on a UQPAY domain (`uqpay.com`, `uqpaytech.com` or a
subdomain of either); any other `qr_code_url` is ignored and nothing is
fetched. That image request is an ordinary HTTPS GET and carries no card
data or token. Your own backend receives
whatever your `tokenProvider` sends it; the SDK does not call it directly.

The SDK does **not**:

- bundle or call any third-party analytics, crash-reporting or advertising
  SDK;
- send data to UQPAY that you did not either enter into a card form or pass
  to the SDK yourself, other than the 3DS snapshot described above;
- read contacts, location, photos, clipboard or any persistent device
  identifier.

A 3-D Secure challenge loads the issuer's page in an in-app webview (Android,
iOS) or as a full-page redirect (web); what the issuer collects on that page
is governed by its own policy. The SDK never reads the page's content.
Wallet payments (WeChat Pay, Alipay, GrabPay, PayNow and others) show a QR
code or payment instructions in-sheet; the customer completes them in their
wallet app, and what that provider collects is governed by its own policy.

## Suggested answers for the store forms

Because you integrate this SDK, your app **does** collect *Financial Info →
Payment Info* (card details) and *Contact Info* (name, email, phone, address
for billing), *linked to the user* if your backend associates the payment
with an account, and used for *App Functionality* only. The SDK does not use
any of it for tracking, advertising or analytics. Declare the device/browser
attributes above under *Device or other IDs* only if your store review
requires it for 3DS; the per-session id is not a persistent identifier.
UQPAY receives them for fraud prevention and authentication.

## Contact

Privacy questions about the SDK: open an issue at
<https://github.com/uqpay/uqpay-sdk-flutter/issues>. Questions about how UQPAY
processes payment data as a payment service provider are covered by UQPAY's own
privacy policy and your merchant agreement.
