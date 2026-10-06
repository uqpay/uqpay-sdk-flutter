<!-- GENERATED FILE — do not edit by hand.
     Regenerate with:
       UPDATE_ERROR_TABLE=1 flutter test test/docs/error_table_test.dart
     The table below is produced from UqpayErrorCode and the SDK's own
     message/retry logic, so it cannot drift from the code. -->

# Error codes

Every error the SDK can report, what causes it, whether the *same* request may
be sent again, and what to tell the customer.

`UqpayErrorCode` is an **open** type. A code this SDK version does not
recognise arrives with `isUnknown == true` and the server's string preserved in
`raw` — it never throws and is never reported as success. Always write your
`switch` with a `default`.

## Outcome-unknown codes are not failures

`timeout`, `server_error`, `rate_limited` and `malformed_response` mean the
server **may have taken the payment**. Reconcile the intent before letting the
customer pay again, and reuse the same idempotency key on any retry.

Retryability is a property of the *occurrence*, not of the code — read
`error.isRetryable` and `error.isOutcomeUnknown` on the error you were given.
The "Retryable" column is read from the SDK's error mapper; "depends" means
the mapper flags some occurrences retryable and others not. A few local failures
raised outside the mapper (for example a missing device IP on a card confirm, or
local storage refusing the idempotency pin) set their own flag, so always read
`error.isRetryable` at runtime. The transport table below shows the concrete
mapping for each transport failure.

| Code | When it happens | Retryable | What you should do | Message shown to the customer |
|---|---|---|---|---|
| `card_declined` | The issuer declined the payment. | no | Ask for a different card. Do not retry the same card blindly. | Your card was declined. Please try a different card or contact your bank. |
| `insufficient_funds` | The issuer declined for lack of funds. | no | Ask for a different card or payment method. | There are not enough funds available. Please try a different card or payment method. |
| `invalid_payment_method` | The payment details or request were rejected as invalid. | no | Check the details you collected, then let the customer re-enter them. | These payment details could not be used. Please check them and try again. |
| `3ds_failed` | 3-D Secure authentication failed or was abandoned. | no | Offer another card, or ask the customer to contact their bank. | Card authentication failed. Please try another card or contact your bank. |
| `cancelled` | The intent or attempt was cancelled. | no | Treat as an abandoned checkout; start a new intent to try again. | The payment was cancelled. |
| `authentication_failed` | The auth token was rejected (401/403), even after one refresh. | no | Your backend must mint a fresh token. Check credentials and clock skew. | The payment could not be started. Please try again later. |
| `invalid_configuration` | The SDK was misconfigured. | see `isRetryable` | A programming error — fix the configuration. It is also thrown as an ArgumentError at init. | The payment could not be started. Please try again later. |
| `network_error` | Socket-level failure: refused, reset, no route, offline. | yes | Retry with the same idempotency key once connectivity returns. | We could not reach the payment service. Please check your connection and try again. |
| `dns_failure` | The host name could not be resolved. The request never left the device. | yes | Safe to retry; no payment was created. | We could not reach the payment service. Please check your connection and try again. |
| `timeout` | The request or a poll budget expired. The payment may still be live. | yes | Never treat as failure. Reconcile the intent before charging again. | We couldn't confirm whether your payment went through. Please wait a moment; do not pay again until you've checked your order. |
| `tls_failure` | The TLS handshake failed. The request never left the device. | no | Do not retry automatically — the same request fails the same way. Check the device clock and for interception proxies; the SDK never accepts a bad certificate. No payment was created. | We could not reach the payment service. Please check your connection and try again. |
| `server_error` | The API answered 5xx. The outcome is unknown. | yes | Retry with the SAME idempotency key, then reconcile. | We couldn't confirm whether your payment went through. Please wait a moment; do not pay again until you've checked your order. |
| `rate_limited` | The API answered 429. The outcome is unknown. | yes | Back off, then retry with the SAME idempotency key. | We couldn't confirm whether your payment went through. Please wait a moment; do not pay again until you've checked your order. |
| `malformed_response` | A 2xx body could not be parsed. The request WAS processed. | no | Reconcile the intent. Never retry blindly — that risks a double charge. | We couldn't confirm whether your payment went through. Please wait a moment; do not pay again until you've checked your order. |
| `unknown` | No more specific classification was possible, or the server sent a code this SDK version does not know — including a server code that happens to spell an SDK-reserved code such as `timeout` or `network_error` (the raw value is kept in `serverCode`). | no | Show userMessage, log code.raw and traceId for support. Never report success. | The payment could not be completed. Please try again. |

## Transport failures

Each distinct transport failure maps to its own code, never to
`unknown`:

| Transport failure | Code | Retryable | Payment may have been taken |
|---|---|---|---|
| `dns` | `dns_failure` | yes | no |
| `socket` | `network_error` | yes | **maybe — reconcile** |
| `timeout` | `timeout` | yes | **maybe — reconcile** |
| `tls` | `tls_failure` | no | no |

On web the browser does not expose DNS or TLS failures separately: a failed
`fetch` is opaque, so both surface as `network_error` (the `socket` row).

## Every error carries

| Field | Purpose |
|---|---|
| `code` | Stable typed code from the table above. |
| `userMessage` | Safe to display as-is. No jargon, no JSON, no server codes. |
| `developerMessage` | For your logs. May contain the server's own wording. |
| `isRetryable` | Whether the same request may be sent again. |
| `isOutcomeUnknown` | Whether the payment may have been taken anyway. |
| `serverCode` | The raw server code, preserved even when unrecognised. |
| `traceId` / `responseId` | From `x-trace-id` / `x-response-id`. Quote these to support. |
| `httpStatus` | The HTTP status, when there was one. |
