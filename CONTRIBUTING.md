# Contributing

Thanks for taking an interest in the UQPAY SDK for Flutter.

This is a vendor-maintained payment SDK, currently a release candidate. The
public API is a compatibility commitment to every merchant who integrates it
(see [STABILITY.md](STABILITY.md)), so changes to it are deliberate and
reviewed closely. Bug reports and small, focused pull requests are welcome; if
you are planning something larger, please open an issue first so we can agree
on the shape before you spend time on it.

Please read the [code of conduct](CODE_OF_CONDUCT.md) before taking part.

## Reporting problems

- **Security vulnerabilities** — do not open an issue. Follow
  [`SECURITY.md`](SECURITY.md).
- **Bugs** — open an issue using the bug template. It asks for the SDK
  version, Flutter version, platform, the payment intent id, the `x-trace-id`
  (`UqpayError.traceId`) and the `UqpayError` code.

**Never put card numbers, security codes, API keys, tokens, or customer
personal data in an issue, a pull request, a commit message, or a test
fixture.** The SDK does not log any of it; please do not add any by hand.

## Getting set up

You need Flutter **3.41.0 or newer** (the floor in `pubspec.yaml`; CI also
runs the newest stable) and, for the platform builds, the usual Android SDK /
JDK 17 and Xcode toolchains.

```sh
git clone https://github.com/uqpay/uqpay-sdk-flutter.git
cd uqpay-sdk-flutter
flutter pub get
(cd example && flutter pub get)
(cd example/backend && dart pub get)
```

All three pub roots must be resolved before `flutter analyze`, which walks
the whole tree.

### Running the example against the sandbox

Credentials live in a root `.env`, which is gitignored and must stay that way.
**Never commit a `.env`, and never paste its values anywhere.**

```sh
cp env.template .env                    # fill in sandbox values
example/backend/tool/run.sh             # reference backend, on 127.0.0.1:8787
example/tool/app_env.sh                 # writes example/app.env (no secrets)
cd example && flutter run --dart-define-from-file=app.env
```

The API key belongs only to the backend. `example/tool/app_env.sh` copies the
three app-safe values (`UQPAY_ENVIRONMENT`, `UQPAY_MERCHANT_BACKEND_URL`,
`UQPAY_ON_BEHALF_OF`) into `example/app.env`, so the key is never passed to
the Flutter build. Do not run the app with `--dart-define-from-file=../.env`.

## Before you open a pull request

Run these from the repository root. CI runs the same checks on the floor
Flutter and the newest stable.

```sh
dart format lib test example/lib example/test example/backend
flutter analyze --fatal-infos
flutter test
(cd example && flutter test)
(cd example/backend && dart test)
```

Formatting is enforced on the floor Flutter version (3.41.x), because the
formatter's output can change between Dart releases. If your local Flutter is
newer and CI's format step disagrees, format with the floor version.

### Goldens and generated files

Some tests compare against checked-in reference output. Regenerate them only
for an intentional change, and review the diff before committing:

```sh
# Sheet, QR and 3-D Secure page screenshots (generated on macOS; review every
# changed PNG)
flutter test --update-goldens test/sheet/sheet_goldens_test.dart \
  test/sheet/qr/uqpay_qr_view_test.dart \
  test/three_ds/challenge_page_goldens_test.dart

# The public API snapshot (every exported symbol with its full signature)
flutter test --update-goldens test/public_api_snapshot_test.dart

# ERROR_CODES.md, generated from the error mapper
UPDATE_ERROR_TABLE=1 flutter test test/docs/error_table_test.dart
```

The public API snapshot in `test/goldens/public_api.txt` records every
exported symbol with its full signature. If `test/public_api_snapshot_test.dart`
fails, either you exported or changed something by accident (fix that), or
the public API changed on purpose: regenerate it with the command above,
review the diff, and record the change in the CHANGELOG.

The README Quickstart is compiled code: `test/docs/readme_quickstart.dart`
must stay byte-identical to the README block. Change both together.

## CHANGELOG

**Any change under `lib/` must add an entry to `CHANGELOG.md` in the same pull
request** — CI fails otherwise. Add it under the topmost unreleased version
heading, written for merchants: what changed for them and what, if anything,
they must do. A breaking change to the public API follows the rules in
[STABILITY.md](STABILITY.md).

## Rules that are not negotiable

This is payment software, so a few things are hard constraints rather than
preferences:

- **No sensitive data in logs.** Not card PAN, security code, expiry, tokens,
  API keys, or customer personal data — not in logs, exceptions,
  `toString()`, or tests. If a value must appear, mask it to the last four
  digits.
- **HTTPS only.** No cleartext origin, and no path that can send a request
  to a host other than the configured UQPAY environment.
- **Nothing card-derived persisted.** Card data never reaches
  `shared_preferences`, `localStorage`, files or cookies.
- **No API key in the app.** Not in the SDK, not in the example, not in a
  `--dart-define`.
- **No analytics or tracking dependencies.**
- **No real card numbers or real credentials in tests.** Use the documented
  sandbox test values and obviously fake keys.

## Pull request checklist

- [ ] Format, analyze (`--fatal-infos`) and all three test suites pass.
- [ ] Tests cover the failure and abuse cases your change touches, not only
      the happy path.
- [ ] `CHANGELOG.md` updated if anything under `lib/` changed.
- [ ] Docs updated (README, `doc/`, `ERROR_CODES.md`) for a public API or
      behaviour change.
- [ ] No secrets, `.env` files, or sensitive data in code, tests, logs, or
      the commit message.

## Licence

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers this project.
