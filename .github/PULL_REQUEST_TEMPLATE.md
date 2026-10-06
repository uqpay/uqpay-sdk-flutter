## What and why

<!-- What does this change, and why? Link the issue it resolves (e.g. "Fixes #123"). -->

## How it was tested

<!-- Tests added or changed, and any manual check (platform, sandbox flow). -->

## Checklist

- [ ] `dart format lib test example/lib example/test example/backend` leaves no changes.
- [ ] `flutter analyze --fatal-infos` passes.
- [ ] `flutter test`, `(cd example && flutter test)` and `(cd example/backend && dart test)` pass.
- [ ] Tests cover failure and abuse cases, not only the happy path.
- [ ] `CHANGELOG.md` has an entry if anything under `lib/` changed.
- [ ] Public API or behaviour changes are reflected in README / `doc/` and follow [STABILITY.md](../STABILITY.md).
- [ ] Goldens / `ERROR_CODES.md` / `test/goldens/public_api.txt` regenerated only for an intentional change.
- [ ] No card numbers, tokens, API keys, `.env` contents or customer data in code, tests, fixtures, logs or this description.
