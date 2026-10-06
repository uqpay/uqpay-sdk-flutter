/// The application shell: themes, and the one screen the app starts on.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:uqpay_sdk_flutter_example/src/config/app_config.dart';
import 'package:uqpay_sdk_flutter_example/src/pages/home_page.dart';
import 'package:uqpay_sdk_flutter_example/src/state/demo_controller.dart';
import 'package:uqpay_sdk_flutter_example/src/state/theme_controller.dart';

/// Root widget. Owns the two controllers and hands them to the screens.
class DemoApp extends StatefulWidget {
  const DemoApp({this.controller, this.themeController, super.key});

  /// Injected by tests; production builds create their own.
  final DemoController? controller;

  /// Injected by tests; production builds create their own.
  final ThemeController? themeController;

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  late final DemoController _controller =
      widget.controller ?? DemoController(config: AppConfig.fromEnvironment());
  late final ThemeController _theme =
      widget.themeController ?? ThemeController();
  late final bool _ownsController = widget.controller == null;

  @override
  void initState() {
    super.initState();
    // Startup work: init, health, the web redirect return, and the reconcile
    // sweep for anything a previous run left in flight.
    unawaited(_controller.bootstrap());
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _theme,
      builder: (context, _) => MaterialApp(
        title: 'UQPAY SDK sample',
        debugShowCheckedModeBanner: false,
        // Both themes are supplied and themeMode is under the tester's
        // control, so the sheet's light/dark behaviour is visible without
        // touching device settings. The SDK never forces brightness.
        theme: _theme.light,
        darkTheme: _theme.dark,
        themeMode: _theme.mode,
        home: HomePage(controller: _controller, theme: _theme),
      ),
    );
  }
}
