// The device's own IP address for the confirm API's `ip_address` field.
//
// `dart.library.js_interop` is the recommended web check: it is true on both
// the JS and the WebAssembly builds, unlike `dart.library.html`.
// On web there are no interfaces to enumerate, so the stub
// reports `null` and the field is omitted rather than invented.
export 'device_ip_stub.dart'
    if (dart.library.js_interop) 'device_ip_stub.dart'
    if (dart.library.io) 'device_ip_io.dart';
