# UQPAY reference merchant backend

A small Dart (`package:shelf`) server that plays the role of **your backend**
for the `uqpay_sdk_flutter` sample app. It is not part of the SDK, is not
published, and is deliberately simple — read it as a reference for the three
things every merchant backend must do, then adapt those to your own stack
(see [Adapting this for your own backend](#adapting-this-for-your-own-backend)).

## Why this exists

Two facts about UQPAY's API shape the whole client/server split:

1. **The API key never belongs in an app.** It can issue refunds and payouts,
   and an app binary cannot keep a secret. The Flutter SDK therefore has *no*
   parameter that accepts an API key; it only ever holds a short-lived
   `auth_token` that your backend obtained.
2. **One active token per merchant.** `POST /api/v1/connect/token` invalidates
   whatever token was issued before. If every device minted its own token,
   each new device would log out every other device *and your own server*.
   Token minting — and therefore payment-intent creation — must live in
   exactly one server-side place.

This backend is that place for the sample app: it holds `UQPAY_API_KEY`,
mints and caches the token (single-flight, refreshed before expiry and on
401), creates payment intents on the app's behalf, and receives UQPAY's
webhooks. A webhook is a hint: before fulfilling, a real server re-reads the
intent with `GET /api/v2/payment_intents/{id}`.

## Run it

```sh
# from the repo root, once:
cp env.template .env          # fill in UQPAY_CLIENT_ID and UQPAY_API_KEY
                              # from the sandbox dashboard (Developer → API Keys)

cd example/backend
dart pub get
tool/run.sh                   # sources ../../.env (or ./.env) if present, never echoes it
```

The server listens on `http://localhost:8787` (override with `PORT`). Point
the sample app's `UQPAY_MERCHANT_BACKEND_URL` at it. On an Android emulator
use `http://10.0.2.2:8787`; on a physical device use your machine's LAN IP.

Environment variables (names match `env.template` exactly):

| Variable | Required | Meaning |
|---|---|---|
| `UQPAY_CLIENT_ID` | yes | sent as `x-client-id` |
| `UQPAY_API_KEY` | yes | sent as `x-api-key` **only** to the token endpoint |
| `UQPAY_ENVIRONMENT` | no (`sandbox`) | `sandbox` → `https://api-sandbox.uqpaytech.com`, `production` → `https://api.uqpay.com` |
| `UQPAY_ALLOW_PRODUCTION` | no | must be `1` before `UQPAY_ENVIRONMENT=production` is accepted — this is a demo server |
| `UQPAY_ON_BEHALF_OF` | no | connected sub-account id, sent as `x-on-behalf-of` |
| `UQPAY_API_BASE_URL_OVERRIDE` | no | https origin overriding the environment host |
| `UQPAY_WEBHOOK_URL` | no | informational; the public URL you registered for `POST /webhooks/uqpay` |
| `PORT` | no (`8787`) | listen port |

The server refuses to start — naming the variable — if `UQPAY_CLIENT_ID` or
`UQPAY_API_KEY` is missing. Log lines mask the client id, key and token to
their last four characters; the raw values are never written anywhere.

## Endpoints

All responses are JSON and carry `Access-Control-Allow-Origin: *` so the
Flutter web sample can call them from a dev origin. Proxied responses forward
the upstream `x-trace-id` header — quote it when contacting UQPAY support.

| Method & path | What it does |
|---|---|
| `GET /health` | `{"ok":true,"environment":"sandbox"}` |
| `POST /client-token` | Returns the current server token: `{"token":"…","expires_at":"<ISO-8601>","auth_token":"…","expired_at":<epoch s>,"client_id":"…"}` (`auth_token` and `expired_at` mirror the shape UQPAY's own token endpoint uses; `client_id` is what the app may pass as `clientId`). Optional JSON body `{"rejected_token_suffix":"<last 4 chars>"}`: the app sends it when the SDK asks for a token again, naming the one it was just refused with. If that is the cached token it has been invalidated elsewhere (one active token per merchant), so a fresh one is minted — single-flight, like the 401 path — instead of replaying the dead one; a suffix that does not match the cache is ignored. Never send the whole token. |
| `POST /payment-intents` | Body `{"amount":"8.98","currency":"USD","return_url":"…","description":"…", …}`. Proxied to `POST /api/v2/payment_intents/create` with the server token, a fresh lowercase-UUID `x-idempotency-key`, and `x-on-behalf-of` if configured. Returns UQPAY's intent JSON verbatim. |
| `GET /payment-intents/{id}` | Proxied to `GET /api/v2/payment_intents/{id}`. |
| `POST /webhooks/uqpay` | Receives UQPAY webhooks; logs `type / intent id / status` and keeps the last 50 in memory. |
| `GET /webhooks/recent` | The stored events, newest first, so you can watch a 3DS outcome arrive. |

### `amount` is a decimal string in major units

`"8.98"` means eight dollars and ninety-eight cents. The server forwards the
string byte-for-byte — no scaling to cents, no rounding, no reformatting —
and rejects a JSON *number* with `400 invalid_amount`, because a number would
be re-serialised (`8.90` → `8.9`) and the contract wants exactly what you
typed.

`description` is required upstream and capped at **32 characters**. The
gateway rejects a violation with a bare `invalid_parameter` that does not name
the field, so this server checks it first and answers `400 invalid_description`
saying exactly what is wrong; omit it entirely and it mints `Order <id>` for
you. If you omit `merchant_order_id` (required upstream) the server mints a
lowercase UUID for it; anything else in the body passes through untouched.

## Hardening defaults (reference behaviour, not production-grade)

| Setting | Default | Notes |
|---|---|---|
| Bind address | `127.0.0.1` | Set `UQPAY_BACKEND_BIND=0.0.0.0` to reach it from a physical device on your LAN (prints a warning). The Android emulator (`adb reverse` or `10.0.2.2`) and the iOS simulator work with the default. |
| CORS | `http://localhost:*`, `http://127.0.0.1:*` | Allow-list, set with `UQPAY_BACKEND_CORS_ORIGINS` (comma-separated). `*` is refused. A browser request from any other origin gets `403` before any route runs; requests with no `Origin` (the mobile app, curl) are unaffected. |
| Forced token re-mint | at most once per 30 s | `POST /client-token` with `{"rejected_token_suffix": "<last 4>"}` mints a new token only when the suffix matches the cached token and the cooldown has passed; otherwise the cached token is returned. |
| `POST /payment-intents` | allow-listed fields only | `amount`, `currency`, `return_url`, `description`, `merchant_order_id`, `metadata`; anything else is `400 unknown_field`. A real backend computes the amount server-side. |
| `GET /webhooks/recent` | metadata only | `event_type`, `payment_intent_id`, `status`, `received_at`; raw payloads are never stored. |

This server is for local development only and says so at startup; it has no
authentication on `/client-token` by design.

## Curl walkthrough

```sh
# 1. Is it up?
curl -s localhost:8787/health

# 2. Create an intent (the app normally does this through the SDK's sample
#    checkout, but you can drive it by hand):
curl -s -i localhost:8787/payment-intents \
  -H 'content-type: application/json' \
  -d '{"amount":"8.98","currency":"USD","return_url":"uqpayexample://payment","description":"Sample order"}'
#    → 200, x-trace-id header, and the payment-intent object; note its "id".

# 3. Read it back:
curl -s localhost:8787/payment-intents/<id-from-step-2>

# 4. Fetch a token the way the sample app does:
curl -s -X POST localhost:8787/client-token

# 5. After the app confirms the intent, UQPAY may send a webhook (a hint;
#    re-read the intent as in step 3 before acting) — expose the port (e.g.
#    with a tunnel), register the URL in the sandbox dashboard, then:
curl -s localhost:8787/webhooks/recent
```

### A note on `client_id`

`POST /client-token` also returns `client_id`. That value is **not** a secret —
the API key is — and the iOS SDK sends it as `x-client-id` on every call. In
the Flutter SDK `clientId` is optional: the sandbox accepts confirms without
it. This server hands it to the app and the sample app passes it
as `clientId`; send it when your backend returns it.

## Adapting this for your own backend

The SDK docs link here as the reference server snippet. Whatever language your
backend is written in, it must do exactly these three things:

**1. Mint the token server-side, once, and cache it.**
`POST {base}/api/v1/connect/token` with headers `x-client-id` and `x-api-key`
and **no body**. The 200 response is `{"auth_token":"…","expired_at":<Unix
epoch seconds>}`; the token lives ~30 minutes. Cache it, refresh it about two
minutes before expiry, refresh it on any 401, and make sure concurrent
requests share one in-flight refresh — a second mint invalidates the first.
See `lib/src/token_manager.dart`.

**2. Create the payment intent from the server.**
`POST {base}/api/v2/payment_intents/create` with headers
`x-auth-token: Bearer <auth_token>`, `x-client-id`, `Content-Type:
application/json`, a lowercase-UUID `x-idempotency-key`, and `x-on-behalf-of`
for connected accounts. Body: `amount` (decimal string, major units),
`currency`, `merchant_order_id`, `return_url`, `description` (**required**,
max 32 characters),
`metadata`, `payment_orders`. Never trust an amount the client sent — compute
it from your own order. See `lib/src/uqpay_client.dart`.

**3. Hand the app only what it needs for that one payment, and fulfil from a
server-side read of the intent.**
Return the intent id plus the short-lived token (this demo's
`POST /client-token`; a real backend would authenticate the user's session
first). That token is the merchant's single, full-scope access token, so read
[What the auth token can do](../../README.md#what-the-auth-token-can-do)
before going live. Then fulfil the order only after your server has called
`GET /api/v2/payment_intents/{id}` and seen a paid status — never from the
SDK's client-side result (a UX signal) and never from a webhook body alone.
A webhook is the prompt to do that read, not proof: UQPAY has not yet
published a webhook signature scheme.

## Notes on the wire contract

Everything above follows the wire contract of UQPAY's iOS SDK. Two things
that contract does not pin down:

- **Webhook envelope and signature.** The iOS SDK never receives webhooks, so
  the contract does not specify the payload shape or a signature scheme. The
  handler here extracts `type` / `event_type`, the intent id and `status`
  best-effort and does *no* signature verification. Verify signatures per
  UQPAY's webhook documentation before trusting a delivery in production.
- **`expired_at` type.** The contract records it as a number of epoch
  seconds while noting the Swift decoders disagree on `Int` vs `Double`; a
  numeric string is also tolerated here. If it is absent, a conservative
  20-minute lifetime is assumed.

## Tests

```sh
cd example/backend
dart test
```

Tests run against an in-process fake UQPAY (`test/helpers.dart`) and cover:
token single-flight, proactive refresh, refresh-and-retry-once on 401 with
the same idempotency key, forced re-issue when the app reports the cached
token's suffix as rejected (and no re-issue when it does not match),
byte-exact `amount` pass-through, rejection of
numeric amounts, missing-env refusal, the production guard, webhook capture
and `x-trace-id` forwarding.
