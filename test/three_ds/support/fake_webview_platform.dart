import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A [WebViewPlatform] that runs on the Dart VM, so the real challenge
/// webview body (`webview_challenge_presenter_io.dart`) can be widget-tested.
///
/// Install with [FakeWebViewPlatform.install]; drive navigations through
/// [FakeWebViewController.navigate] and inspect what the page did.
class FakeWebViewPlatform extends WebViewPlatform {
  /// Every controller created, in order.
  final List<FakeWebViewController> controllers = <FakeWebViewController>[];

  /// How many times a cookie manager was created (the global cookie API).
  int cookieManagersCreated = 0;

  /// When set, controller hygiene calls throw this (sync) error.
  Error? hygieneThrows;

  /// The last controller created.
  FakeWebViewController get last => controllers.last;

  /// Installs a fresh fake as `WebViewPlatform.instance` and returns it.
  static FakeWebViewPlatform install() {
    final platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    return platform;
  }

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = FakeWebViewController(params, this);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) {
    cookieManagersCreated++;
    throw StateError('the SDK must never touch the app-global cookie jar');
  }
}

/// Records what the page asked the webview to do.
class FakeWebViewController extends PlatformWebViewController {
  /// Creates a controller owned by [platform].
  FakeWebViewController(super.params, this.platform) : super.implementation();

  /// The owning platform.
  final FakeWebViewPlatform platform;

  /// The navigation delegate the page installed.
  FakeNavigationDelegate? delegate;

  /// URLs passed to loadRequest.
  final List<Uri> loadedRequests = <Uri>[];

  /// HTML passed to loadHtmlString.
  final List<String> loadedHtml = <String>[];

  /// Hygiene call counters.
  int clearCacheCalls = 0;

  /// Hygiene call counters.
  int clearLocalStorageCalls = 0;

  /// Simulates the page navigating to [url]; returns the page's decision.
  Future<NavigationDecision> navigate(
    String url, {
    bool isMainFrame = true,
  }) async => delegate!.onNavigationRequest!(
    NavigationRequest(url: url, isMainFrame: isMainFrame),
  );

  /// Simulates a resource load error.
  void error({required bool isForMainFrame}) => delegate!.onWebResourceError!(
    WebResourceError(
      errorCode: -2,
      description: 'host lookup failed',
      isForMainFrame: isForMainFrame,
    ),
  );

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    delegate = handler as FakeNavigationDelegate;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedRequests.add(params.uri);
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    loadedHtml.add(html);
  }

  @override
  Future<void> clearCache() {
    clearCacheCalls++;
    final failure = platform.hygieneThrows;
    if (failure != null) {
      throw failure;
    }
    return Future<void>.value();
  }

  @override
  Future<void> clearLocalStorage() {
    clearLocalStorageCalls++;
    final failure = platform.hygieneThrows;
    if (failure != null) {
      return Future<void>.error(failure);
    }
    return Future<void>.value();
  }
}

/// Captures the callbacks the page registers.
class FakeNavigationDelegate extends PlatformNavigationDelegate {
  /// Creates a delegate.
  FakeNavigationDelegate(super.params) : super.implementation();

  /// The page's navigation policy.
  NavigationRequestCallback? onNavigationRequest;

  /// The page's error handler.
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback onHttpAuthRequest,
  ) async {}

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback onSslAuthError) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey<String>('fake-webview'));
}
