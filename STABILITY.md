# Stability policy

What `uqpay_sdk_flutter` promises about its API, how long it keeps that promise, and
which Flutter versions it runs on. This file is the contract behind the semver claim in
the README. The guarantees below start at 1.0.0; a release candidate (`1.0.0-rc.N`) may
still change platform floors and experimental members.

## 1. What counts as the public API

The public API is **exactly** what these two libraries export, and nothing else:

- `package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart` — the drop-in sheet plus everything below
- `package:uqpay_sdk_flutter/headless.dart` — the typed API, with no widgets

Anything reachable only through `package:uqpay_sdk_flutter/src/...` is **internal**. It may
change or disappear in any release, including a patch. Importing it is not supported, and
we will not treat a break there as a regression.

The exported symbol list is pinned by a golden file (`test/goldens/public_api.txt`) and a
test fails on **any** addition or removal. That is deliberate: it makes every change to the
public surface a conscious, reviewed decision rather than an accident.

## 2. Semantic versioning, and what "breaking" means in Dart

We follow [semver](https://semver.org) strictly. No breaking change ships in a minor or a
patch release.

Dart makes several changes breaking that are additive in other languages. All of the
following require a **major** version:

| Change | Why it breaks |
|---|---|
| Adding a subclass to a `sealed` type | Every merchant's exhaustive `switch` stops compiling |
| Adding a required parameter (positional or named) | Existing call sites stop compiling |
| Renaming or removing an exported symbol | Imports and references break |
| Narrowing a parameter type, or widening a return type | Existing code may no longer type-check |
| Making a nullable field non-nullable, or vice versa | Assignments and null checks break |
| Adding an abstract member to an interface a merchant may implement | Their implementation stops compiling |

Three sealed hierarchies are **frozen for the whole 1.x line**:

- `UqpayPaymentResult` = `UqpayPaymentCompleted | UqpayPaymentFailed | UqpayPaymentCanceled | UqpayPaymentPending`
- `UqpayChallengeOutcome` = returned | dismissedByUser | failed | timedOut
- `UqpaySheetPresentation` = `methodList() | cardOnly() | singleWallet(method)`

### Which types you may implement or extend

Types designed for you to implement or subclass are covered by the "abstract member" rule
above: `UqpayChallengePresenter` (present 3-D Secure your own way), `UqpayClock` (a fake
clock in tests) and `UqpayLocalizations` (your own strings).

`UqpayPayments`, `UqpayPaymentFlow` and `UqpayPaymentSheet` are **not** meant to be
implemented or extended by merchants. They are plain classes only so the SDK can construct
them; a minor release may add members to them, and a fake that `implements` or `extends`
one may stop compiling or start failing at runtime (for example, the sheet calls members of
`UqpayPayments` that a fake does not override). There is no guarantee for such fakes. Test
at the **result-handling** level instead: construct `UqpayPaymentResult` values directly and
put the sheet call behind a small interface of your own — see
[Unit testing your checkout](doc/integration-guide.md#unit-testing-your-checkout).

New outcomes are **not** expressed as new subclasses. They are expressed as new
`UqpayErrorCode` values inside the existing `failed` cases — which is safe precisely
because error codes are an open type (see
[section 3](#3-types-that-are-deliberately-open)).

## 3. Types that are deliberately open

`UqpayErrorCode`, `UqpayIntentStatus`, `UqpayAttemptStatus`, `UqpayCancelReason` and
`UqpayPaymentPhase` are **not** Dart `enum`s. Each is a value type wrapping a `String`,
with static constants for the values we know and an `isUnknown` escape hatch that
preserves the server's raw value.

This is a load-bearing decision, not a style preference. The payments API can introduce a
new status or decline code at any time, without a client release. If these were enums:

- a merchant's exhaustive `switch` would break the moment we added a constant, and
- a value we had never seen would fail to parse and could take down a live payment.

So: **adding a new constant to one of these types is not a breaking change.** Write your
`switch` statements with a `default`, and treat `isUnknown` as "something newer than this
SDK version" — never as an error in itself.

## 4. Deprecation window

Nothing is removed without notice.

1. The symbol is marked `@Deprecated('... Use X instead. Removed in 2.0.0.')`. The message
   always names the replacement.
2. It keeps working, unchanged, for **at least two minor releases**.
3. It is removed only in the next **major** release.

Deprecations are listed in `CHANGELOG.md` under the release that introduced them, with a
**Migration** subsection describing what to change.

## 5. Supported Flutter and Dart versions

We support the **current stable Flutter minor and the two before it** (stable N-2), and the
Dart version each of those ships with. CI builds and runs the full suite against both the
floor and the current stable on every pull request — a version we do not test is a version
we do not claim.

Raising the floor is a **minor** version bump, announced in the changelog. We will not raise
it inside a patch release.

The current floors are in the README's compatibility matrix, which is kept in step with
`pubspec.yaml`. Platform floors (Android `minSdk`, iOS deployment target, browsers) follow
the same rule and appear in the same table.

## 6. Behaviour, not just signatures

An API that compiles but behaves differently is also a break. These behaviours are part of
the contract and will not change within 1.x:

- **A result is delivered exactly once** per payment attempt, on every exit path.
- **Expected outcomes are returned, not thrown.** A decline, a cancellation, a timeout or a
  4xx completes the future with a result. Exceptions are reserved for programmer error —
  misconfiguration such as an empty intent id or a missing `tokenProvider`.
- **Amounts are never rescaled.** The server's decimal string is preserved exactly; the
  currency exponent is a formatting input only.
- **A confirm already in flight is never reported as cancelled** — it resolves as `Pending`.
- **The client result is a UX signal, not proof of payment.** Fulfilment must be driven by
  your server, after it retrieves the intent from the UQPAY API; a webhook is only the
  prompt to do that. This will never change.

## 7. What is not covered

- Anything under `lib/src/`.
- The `example/` app and `example/backend/`, which are reference material, not published API.
- Exact wording of user-facing strings, and the visual design of the sheet. Both may change
  in a minor release; if you depend on precise wording, supply your own localizations.
- Experimental members, marked as such in their dartdoc. The wallet confirm models are
  currently experimental because their request shape is not yet confirmed against a live
  sandbox for every method.

## 8. Reporting a break

If a minor or patch release breaks you, that is a bug in this policy's application, not an
expected cost of upgrading. Please open an issue with the version you moved from and to,
and the code that stopped working.
