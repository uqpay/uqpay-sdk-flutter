/// In-memory ring buffer of recent webhook deliveries.
///
/// UQPAY reports the 3DS outcome by webhook, not in the confirm response. A
/// webhook is unsigned, so a real merchant treats it as a prompt: it
/// re-fetches the intent from UQPAY and fulfils from that. This demo keeps
/// the last few deliveries so a developer can watch them arrive at
/// `GET /webhooks/recent`.
///
/// Only four summary fields are kept. The raw payload — which can carry
/// customer data — is dropped on arrival: never stored, logged or served.
library;

import 'dart:collection';

/// The parts of a webhook we surface. Nothing else from the payload is kept.
class WebhookEvent {
  WebhookEvent({
    required this.receivedAt,
    required this.eventType,
    required this.paymentIntentId,
    required this.status,
  });

  /// Best-effort extraction. The wire contract does not specify the webhook
  /// envelope, so several plausible key names are tried.
  factory WebhookEvent.fromPayload(Object? payload, DateTime receivedAt) {
    // The endpoint is unauthenticated, so every kept value is cut to a sane
    // length and stripped of control characters before it can reach the log
    // (no forged log lines) or memory (no 50 × megabyte strings).
    String? str(Object? v) {
      if (v is! String) return null;
      final clean = v.replaceAll(_controlChars, '');
      if (clean.isEmpty) return null;
      return clean.length <= maxFieldLength
          ? clean
          : clean.substring(0, maxFieldLength);
    }

    Map<String, Object?>? map(Object? v) =>
        v is Map<String, Object?> ? v : null;

    final root = map(payload) ?? const <String, Object?>{};
    final data = map(root['data']) ?? map(root['object']) ?? root;
    return WebhookEvent(
      receivedAt: receivedAt,
      eventType:
          str(root['type']) ??
          str(root['event_type']) ??
          str(root['event']) ??
          str(root['name']),
      paymentIntentId:
          str(data['payment_intent_id']) ??
          str(map(data['payment_intent'])?['id']) ??
          str(data['id']) ??
          str(root['payment_intent_id']),
      status:
          str(data['status']) ??
          str(data['intent_status']) ??
          str(root['status']),
    );
  }

  /// Longest value kept for any one field.
  static const int maxFieldLength = 128;

  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');

  final DateTime receivedAt;
  final String? eventType;
  final String? paymentIntentId;
  final String? status;

  /// What `GET /webhooks/recent` serves: these four fields and never the
  /// payload.
  Map<String, Object?> toJson() => {
    'received_at': receivedAt.toUtc().toIso8601String(),
    'event_type': eventType,
    'payment_intent_id': paymentIntentId,
    'status': status,
  };

  /// One log line with nothing sensitive in it.
  String get summary =>
      'webhook: type=${eventType ?? '?'} intent=${paymentIntentId ?? '?'} '
      'status=${status ?? '?'}';
}

class WebhookStore {
  WebhookStore({this.capacity = 50});

  final int capacity;
  final ListQueue<WebhookEvent> _events = ListQueue<WebhookEvent>();

  void add(WebhookEvent event) {
    _events.addLast(event);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
  }

  /// Newest first.
  List<WebhookEvent> get recent => _events.toList().reversed.toList();
}
