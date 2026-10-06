/// Sample app for the UQPAY Flutter SDK.
///
/// Run it against the sandbox with only a config change:
///
/// ```sh
/// cp env.template .env          # from the repo root, then fill it in
/// example/backend/tool/run.sh   # the backend reads .env (API key included)
/// example/tool/app_env.sh       # writes example/app.env: 3 app-safe keys
/// cd example && flutter run -d chrome --dart-define-from-file=app.env
/// ```
///
/// Never pass the root `.env` to the Flutter build: it holds the API key,
/// which belongs to the backend only.
///
/// See `example/README.md` for the full runbook and the test checklist.
library;

import 'package:flutter/material.dart';

import 'package:uqpay_sdk_flutter_example/src/demo_app.dart';

void main() {
  runApp(const DemoApp());
}
