import 'dart:io';

/// The device's current IP address, IPv4 preferred, or `null` when no usable
/// interface is up.
///
/// This is the address of an active network interface. Behind NAT that is a
/// private address, which is still the honest client-side value — the same
/// choice the iOS SDK makes in `UqpayDeviceIP.swift`. The SDK never
/// fabricates a public address: the gateway checks only that `ip_address` is
/// present (observed against the sandbox: a literal `"not-an-ip"` is accepted),
/// so a plausible-looking constant would sail through and quietly corrupt the
/// issuer's risk scoring on every payment.
///
/// Loopback and link-local addresses are skipped: they say nothing about the
/// customer's network. Never throws — a payment must not fail because an
/// interface could not be enumerated.
Future<String?> resolveDeviceIpAddress() async {
  try {
    final interfaces = await NetworkInterface.list();
    String? fallback;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback || address.isLinkLocal) {
          continue;
        }
        if (address.type == InternetAddressType.IPv4) {
          return address.address;
        }
        fallback ??= address.address;
      }
    }
    return fallback;
  } on Object {
    // Enumeration can fail on a restricted platform or a device with no
    // interfaces up. Omitting the field is correct; inventing one is not.
    return null;
  }
}
