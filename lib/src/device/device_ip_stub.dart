/// The web build has no network interfaces to enumerate, so there is no
/// device IP to report.
///
/// Returning `null` omits `ip_address` from the confirm rather than sending
/// something invented. Card entry does not run on web anyway; a
/// wallet confirm from a browser reaches the gateway without the field.
Future<String?> resolveDeviceIpAddress() async => null;
