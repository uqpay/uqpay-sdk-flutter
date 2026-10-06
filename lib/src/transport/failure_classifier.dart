// Platform-specific classification of low-level transport errors.
//
// `dart.library.js_interop` is the recommended web check: it is true on both
// the JS and the WebAssembly builds, unlike `dart.library.html`.
export 'failure_classifier_stub.dart'
    if (dart.library.js_interop) 'failure_classifier_stub.dart'
    if (dart.library.io) 'failure_classifier_io.dart';
