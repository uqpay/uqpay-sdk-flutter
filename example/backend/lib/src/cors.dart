/// Origin allow-list for the reference backend's CORS handling.
///
/// The backend hands out a merchant token, so a wildcard
/// `Access-Control-Allow-Origin: *` would let any web page the developer
/// visits read that token from `http://localhost:8787`. Instead, an origin is
/// reflected only when it matches the allow-list, and a browser request from
/// any other origin is refused before it reaches a route.
library;

/// One allow-list entry: `scheme://host` plus an exact port, or `:*` for any
/// port on that host.
class _OriginPattern {
  _OriginPattern(this.scheme, this.host, this.port);

  final String scheme;
  final String host;

  /// `null` means any port.
  final int? port;

  bool matches(Uri origin) =>
      origin.scheme == scheme &&
      origin.host.toLowerCase() == host &&
      (port == null || origin.port == port);
}

/// Thrown for an allow-list entry that is not a plain http(s) origin.
class CorsConfigError implements Exception {
  CorsConfigError(this.message);

  final String message;

  @override
  String toString() => 'CorsConfigError: $message';
}

/// Which browser origins may call the backend.
class CorsPolicy {
  CorsPolicy._(this._patterns, this.entries);

  /// Parses allow-list [entries] such as `http://localhost:*` or
  /// `https://dev.example.com:8443`. Throws [CorsConfigError] for `*`, a
  /// non-http(s) scheme, or anything carrying a path, query or credentials.
  factory CorsPolicy.parse(Iterable<String> entries) {
    final patterns = <_OriginPattern>[];
    final kept = <String>[];
    for (final raw in entries) {
      final entry = raw.trim();
      if (entry.isEmpty) continue;
      if (entry == '*') {
        throw CorsConfigError(
          'a wildcard "*" origin is not allowed: it would let any web page '
          'read the merchant token. List the dev origins instead.',
        );
      }
      final anyPort = entry.endsWith(':*');
      final uri = Uri.tryParse(
        anyPort ? entry.substring(0, entry.length - 2) : entry,
      );
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          uri.hasQuery ||
          uri.hasFragment ||
          (anyPort && uri.hasPort)) {
        throw CorsConfigError(
          'each origin must look like http://host, http://host:port or '
          'http://host:* (got an entry that does not).',
        );
      }
      patterns.add(
        _OriginPattern(
          uri.scheme,
          uri.host.toLowerCase(),
          anyPort ? null : uri.port,
        ),
      );
      kept.add(entry);
    }
    return CorsPolicy._(patterns, List.unmodifiable(kept));
  }

  /// Local dev origins only: `flutter run -d chrome` serves the web sample
  /// from `http://localhost:<random port>`.
  static const List<String> defaultOrigins = [
    'http://localhost:*',
    'http://127.0.0.1:*',
  ];

  /// The default policy, [defaultOrigins].
  static final CorsPolicy localDev = CorsPolicy.parse(defaultOrigins);

  final List<_OriginPattern> _patterns;

  /// The entries this policy was built from, for the startup log.
  final List<String> entries;

  /// Whether a request carrying `Origin: <origin>` may be served. The opaque
  /// origin `null` (sandboxed iframes, `file:` pages) is never allowed.
  bool allows(String origin) {
    if (origin == 'null') return false;
    final uri = Uri.tryParse(origin);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    return _patterns.any((p) => p.matches(uri));
  }
}
