# Security Policy

`uqpay_sdk_flutter` handles payment data for merchant apps. We take reports
about it seriously and would much rather hear about a problem early than read
about it later.

## Supported versions

| Version | Supported |
| ------- | --------- |
| `1.0.0-rc.x` (release candidate) | ✅ Current development line |

Once `1.0.0` ships, this table will list the release lines that receive
security fixes. A version published to pub.dev is immutable, so a fix always
ships as a new version: upgrade to the latest release to get it.

## Reporting a vulnerability

**Please do not open a public GitHub issue for a security problem.** A public
issue tells everyone about the weakness before merchants have a fixed version
to move to.

Use **GitHub's private vulnerability reporting** instead:

> [uqpay/uqpay-sdk-flutter](https://github.com/uqpay/uqpay-sdk-flutter) →
> **Security** tab → **Report a vulnerability**
> (direct link: <https://github.com/uqpay/uqpay-sdk-flutter/security/advisories/new>)

That opens a private channel visible only to the maintainers. It keeps the
whole exchange in one place, and it lets us credit you when the fix ships.

**If you cannot use GitHub, email [it@uqpay.com](mailto:it@uqpay.com)** with
`SECURITY` in the subject line. Plain email is not encrypted, so keep the first
message short — what the issue affects and roughly how severe you believe it is
— and we will arrange a secure channel before you send details or any proof of
concept.

### What to include

- The `uqpay_sdk_flutter` version, your Flutter version (`flutter --version`),
  and the platform: Android, iOS or web, with the OS or browser version and
  device model.
- What an attacker can achieve, and the steps to reproduce it.
- Any proof-of-concept code, and the impact you believe it has.

**Never include real card numbers, security codes, API keys, access tokens, or
customer personal data in a report.** Use sandbox test values. If a real value
is genuinely necessary to explain the issue, say so and we will arrange a safer
channel — do not paste it. Mask anything you must reference, for example a card
as `•••• •••• •••• 1234`.

## What to expect

These are our targets, measured in business days:

| Stage | Target |
| ----- | ------ |
| Acknowledgement that we received the report | 3 days |
| Initial assessment and a severity judgement | 10 days |
| Fix or documented mitigation for a confirmed high-severity issue | 30 days |

We will keep you updated if something takes longer, and we will tell you when a
fix ships.

## Scope

**In scope** — anything in this repository: the Dart library under `lib/`
(transport, token handling, idempotency storage, the payment sheet and card
form, 3-D Secure presenters and return handling), the example app, the
reference backend under `example/backend/`, and the CI and publishing
workflows.

**Out of scope:**

- The UQPAY gateway and platform APIs. Those are a separate system with a
  separate reporting path; contact UQPAY directly rather than filing here.
- The native UQPAY SDKs. Report those to
  [uqpay-sdk-ios](https://github.com/uqpay/uqpay-sdk-ios) and
  [uqpay-sdk-android](https://github.com/uqpay/uqpay-sdk-android).
- Flutter, the Dart SDK and first-party plugins (`webview_flutter`,
  `url_launcher`, `shared_preferences`, `http`). Report those upstream.
- Reports that depend on a rooted, jail-broken or otherwise compromised
  device, on the host app deliberately misusing the public API, or on
  credentials the reporter already controls.
- The reference backend's documented demo shortcuts (an unauthenticated
  token route, no user sessions). It is a local development server, not a
  server to deploy; its README lists what a real backend must do instead.
  A way to reach it from another machine or web page *despite* its loopback
  binding and CORS allow-list is in scope.

## What the SDK never does

These are design guarantees. A way to make the SDK break any of them is a
vulnerability we want to hear about:

- **It never holds a UQPAY API key** and has no parameter that accepts one.
  It authenticates with a short-lived token your backend mints, and never
  calls the token endpoint itself.
- **It never talks to any host other than UQPAY**, and never over cleartext:
  a non-`https` origin is rejected at `UqpaySdk.init`, and a hosted QR image
  (`qr_code_url`) is downloaded only over `https` from `uqpay.com`,
  `uqpaytech.com` or their subdomains — any other host is ignored and the
  raw QR payload is rendered locally instead. It bundles no analytics,
  crash-reporting or advertising SDK.
- **It never writes card data to storage** — no PAN, CVC, expiry or
  cardholder name in `shared_preferences`, `localStorage`, files or cookies.
  The only things stored are idempotency pins and an in-flight intent id. A
  pin carries a 64-bit non-reversible hash of the redacted confirm request
  (card number cut to first 6 + last 4, CVC removed, device snapshot
  excluded) so a retry can find its key (see [PRIVACY.md](PRIVACY.md)).
- **It never logs card data, tokens or request/response bodies.** Logging is
  off by default and, when enabled, carries identifiers and status words
  only.
- **It never treats a client-side result as proof of payment.** The merchant
  server retrieves the intent before fulfilling an order.

The SDK deliberately does **not** pin certificates: a certificate rotation
would become a total payment outage for every installed app with no
server-side remedy. TLS validation follows the platform's trust store. This
is a considered position, not an unfinished control, so a report that only
says "no pinning" is out of scope.

## Coordinated disclosure

We ask that you give us a reasonable window to ship a fix before publishing
details — we aim to agree a disclosure date with you once a fix is ready, and
we publish a GitHub security advisory crediting you (unless you prefer not to
be named) when the fixed version is on pub.dev. We will not take legal action
against anyone who reports a vulnerability in good faith, follows this policy,
and avoids privacy violations, data destruction, and any disruption to
production systems or real payments.
