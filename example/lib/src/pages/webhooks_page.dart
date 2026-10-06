/// Watches `GET /webhooks/recent` on the merchant backend.
///
/// This screen exists to make one point concrete: the payment outcome that
/// matters arrives at your **server**, by webhook. The client result is a UX
/// signal.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:uqpay_sdk_flutter_example/src/backend/merchant_backend.dart';
import 'package:uqpay_sdk_flutter_example/src/state/demo_controller.dart';
import 'package:uqpay_sdk_flutter_example/src/widgets/common.dart';

/// A polling view of the webhooks the backend has received.
class WebhooksPage extends StatefulWidget {
  const WebhooksPage({required this.controller, super.key});

  final DemoController controller;

  @override
  State<WebhooksPage> createState() => _WebhooksPageState();
}

class _WebhooksPageState extends State<WebhooksPage> {
  static const Duration _interval = Duration(seconds: 3);

  Timer? _timer;
  List<WebhookEventView> _events = const <WebhookEventView>[];
  MerchantBackendException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(_interval, (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final events = await widget.controller.backend.recentWebhooks();
      if (!mounted) {
        return;
      }
      setState(() {
        _events = events;
        _error = null;
        _loading = false;
      });
    } on MerchantBackendException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Webhooks'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh now',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          if (_loading) const LinearProgressIndicator(),
          const SectionCard(
            title: 'Webhook deliveries: a prompt, not proof',
            icon: Icons.gpp_good_outlined,
            children: <Widget>[
              Text(
                'UQPAY tells your server about a payment outcome — 3-D Secure '
                'results in particular — by webhook, not in the confirm '
                'response. A webhook is a prompt: your server fulfils the '
                'order only after it retrieves the intent from UQPAY. What '
                'the app shows is a UX signal only.',
              ),
              Note(
                'Polling GET /webhooks/recent every 3 seconds. The reference '
                'backend keeps the last 50 deliveries in memory and verifies '
                'no signature — verify signatures before trusting a delivery '
                'in production.',
                icon: Icons.info_outline,
              ),
              Note(
                'Deliveries only arrive if the sandbox dashboard has a public '
                'URL registered for POST /webhooks/uqpay — expose the backend '
                'with a tunnel and set UQPAY_WEBHOOK_URL. Without that this '
                'list stays empty, and that is expected.',
                icon: Icons.public,
              ),
            ],
          ),
          if (_error != null)
            SectionCard(
              title: _error!.summary,
              icon: Icons.cloud_off,
              tone: theme.colorScheme.errorContainer,
              children: <Widget>[SelectableText(_error!.detail)],
            ),
          if (_error == null && _events.isEmpty && !_loading)
            const SectionCard(
              title: 'No deliveries yet',
              icon: Icons.inbox_outlined,
              children: <Widget>[
                Text(
                  'Complete a payment, then watch this list. If it stays '
                  'empty the webhook URL is not reachable from UQPAY.',
                ),
              ],
            ),
          for (final event in _events)
            SectionCard(
              title: event.eventType ?? 'webhook',
              icon: Icons.bolt_outlined,
              children: <Widget>[
                LabelledValue(label: 'Received', value: event.receivedAt),
                LabelledValue(
                  label: 'Intent',
                  value: event.paymentIntentId ?? '—',
                  monospace: true,
                ),
                LabelledValue(label: 'Status', value: event.status ?? '—'),
              ],
            ),
        ],
      ),
    );
  }
}
