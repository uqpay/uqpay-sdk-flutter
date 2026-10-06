/// The UQPAY deployment an [UqpayEnvironment] value resolves to.
///
/// Sandbox and production credentials are separate and not interchangeable, so
/// selecting the wrong environment fails authentication rather than silently
/// transacting against the wrong ledger.
enum UqpayEnvironment {
  /// The sandbox environment, backed by `https://api-sandbox.uqpaytech.com`.
  ///
  /// Test cards work here and no money moves. Use this for development and for
  /// every automated test that talks to a real server.
  sandbox('https://api-sandbox.uqpaytech.com'),

  /// The production environment, backed by `https://api.uqpay.com`.
  ///
  /// Real money moves here.
  production('https://api.uqpay.com')
  ;

  /// Associates each environment with the API origin it talks to.
  const UqpayEnvironment(this.baseUrl);

  /// The HTTPS origin every request for this environment is sent to.
  ///
  /// Always an `https` origin with no trailing slash and no path. The SDK
  /// refuses to send a request to a non-HTTPS origin.
  final String baseUrl;

  /// [baseUrl] parsed as a [Uri].
  ///
  /// Provided so callers never have to concatenate strings to build a request
  /// path.
  Uri get baseUri => Uri.parse(baseUrl);
}
