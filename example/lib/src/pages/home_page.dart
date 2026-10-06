/// The sample app's front screen: configuration, the order, and the two API
/// surfaces side by side.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';
import 'package:uqpay_sdk_flutter_example/src/pages/headless_page.dart';
import 'package:uqpay_sdk_flutter_example/src/pages/webhooks_page.dart';
import 'package:uqpay_sdk_flutter_example/src/state/demo_controller.dart';
import 'package:uqpay_sdk_flutter_example/src/state/theme_controller.dart';
import 'package:uqpay_sdk_flutter_example/src/widgets/common.dart';
import 'package:uqpay_sdk_flutter_example/src/widgets/result_view.dart';

/// Front screen. Everything a tester needs to reach a sandbox payment.
class HomePage extends StatefulWidget {
  const HomePage({required this.controller, required this.theme, super.key});

  final DemoController controller;
  final ThemeController theme;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// How the sheet opens — the three `UqpaySheetPresentation`s, so a tester
  /// can see card-only and single-wallet checkout without code changes.
  UqpaySheetPresentation _presentation =
      const UqpaySheetPresentation.methodList();

  /// When on, `allowedPaymentMethods` restricts the sheet to card + Alipay.
  bool _restrictMethods = false;

  late final TextEditingController _amount = TextEditingController(
    text: widget.controller.amount,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.controller.description,
  );

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[controller, widget.theme]),
      builder: (context, _) {
        if (_amount.text != controller.amount) {
          _amount.text = controller.amount;
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('UQPAY SDK sample'),
            actions: <Widget>[
              IconButton(
                key: const Key('theme-mode-button'),
                tooltip: 'Theme: ${widget.theme.modeLabel}',
                onPressed: widget.theme.cycleMode,
                icon: Icon(widget.theme.modeIcon),
              ),
              IconButton(
                key: const Key('brand-toggle-button'),
                tooltip: widget.theme.brandOverride
                    ? 'Custom brand appearance: on'
                    : 'Custom brand appearance: off',
                onPressed: widget.theme.toggleBrandOverride,
                icon: Icon(
                  widget.theme.brandOverride
                      ? Icons.palette
                      : Icons.palette_outlined,
                  color: widget.theme.brandOverride
                      ? ThemeController.brandSeed
                      : null,
                ),
              ),
              IconButton(
                key: const Key('webhooks-button'),
                tooltip: 'Webhooks',
                onPressed: _openWebhooks,
                icon: const Icon(Icons.podcasts_outlined),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              if (controller.busy != null)
                const LinearProgressIndicator(
                  key: Key('busy-indicator'),
                ),
              if (controller.environment == UqpayEnvironment.production)
                const _ProductionBanner(),
              _configCard(context),
              _backendCard(context),
              if (controller.notice != null) _noticeCard(context),
              if (controller.unresolved.isNotEmpty) _unresolvedCard(context),
              _orderCard(context),
              _surfacesCard(context),
              if (controller.result != null) _resultCard(context),
              _truthCard(context),
            ],
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ cards

  Widget _configCard(BuildContext context) {
    final controller = widget.controller;
    final config = controller.config;
    return SectionCard(
      title: 'Configuration',
      icon: Icons.tune,
      subtitle:
          'From --dart-define-from-file=app.env. Three keys are read and no '
          'credential is among them: an API key belongs on your backend.',
      children: <Widget>[
        SegmentedButton<UqpayEnvironment>(
          key: const Key('environment-switch'),
          segments: const <ButtonSegment<UqpayEnvironment>>[
            ButtonSegment<UqpayEnvironment>(
              value: UqpayEnvironment.sandbox,
              icon: Icon(Icons.science_outlined),
              label: Text('Sandbox'),
            ),
            ButtonSegment<UqpayEnvironment>(
              value: UqpayEnvironment.production,
              icon: Icon(Icons.warning_amber_rounded),
              label: Text('PRODUCTION'),
            ),
          ],
          selected: <UqpayEnvironment>{controller.environment},
          onSelectionChanged: (selection) =>
              _changeEnvironment(selection.first),
        ),
        const SizedBox(height: 10),
        LabelledValue(
          label: 'Active environment',
          value: controller.environment.name,
        ),
        LabelledValue(
          label: 'UQPAY_ENVIRONMENT',
          value: config.environmentRecognised
              ? config.rawEnvironment
              : '${config.rawEnvironment} (not recognised — using sandbox)',
        ),
        LabelledValue(
          label: 'API origin',
          value: controller.sdk?.baseUrl ?? '—',
          monospace: true,
        ),
        LabelledValue(
          label: 'Merchant backend',
          value: config.backendUrlRecognised
              ? config.backendBaseUrl
              : '${config.rawBackendUrl} (unusable — using '
                    '${config.backendBaseUrl})',
          monospace: true,
        ),
        LabelledValue(
          label: 'On behalf of',
          value: config.onBehalfOf ?? '— (direct account)',
        ),
        LabelledValue(
          label: 'x-client-id',
          value: controller.sdk?.clientId ?? 'not disclosed by the backend',
        ),
        LabelledValue(label: 'Platform', value: _platformLabel),
        LabelledValue(
          label: 'return_url',
          value: controller.returnUrl.toString(),
          monospace: true,
        ),
        if (controller.parameterisedReturnUrl != null)
          LabelledValue(
            label: 'return_url + id',
            value: controller.parameterisedReturnUrl.toString(),
            monospace: true,
          ),
        if (config.productionRequested)
          const Note(
            'UQPAY_ENVIRONMENT asked for production. The switch above still '
            'starts on sandbox — flipping it is a deliberate action.',
            icon: Icons.info_outline,
          ),
        if (controller.sdkError != null)
          Note(controller.sdkError!, icon: Icons.error_outline),
        if (kIsWeb)
          const Note(
            'Web: the sheet offers wallet / QR / redirect methods and never '
            'a card form. Card fields in the merchant origin would push a '
            'merchant from SAQ A to SAQ A-EP, so card entry is not available '
            'in the browser in this version.',
            icon: Icons.security_outlined,
          ),
      ],
    );
  }

  Widget _backendCard(BuildContext context) {
    final controller = widget.controller;
    final error = controller.backendError;
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'Merchant backend',
      icon: switch (controller.backendStatus) {
        BackendStatus.ready => Icons.check_circle_outline,
        BackendStatus.failed => Icons.cloud_off,
        _ => Icons.cloud_queue,
      },
      tone: controller.backendStatus == BackendStatus.failed
          ? scheme.errorContainer
          : null,
      children: <Widget>[
        LabelledValue(
          label: 'Status',
          value: switch (controller.backendStatus) {
            BackendStatus.unknown => 'not checked',
            BackendStatus.checking => 'checking…',
            BackendStatus.ready =>
              'reachable — token issued, environment '
                  '${controller.backendEnvironment}',
            BackendStatus.failed => 'unreachable or refusing',
          },
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            error.summary,
            key: const Key('backend-error-summary'),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: scheme.onErrorContainer),
          ),
          const SizedBox(height: 6),
          SelectableText(
            error.detail,
            key: const Key('backend-error-detail'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (error.traceId != null)
            LabelledValue(
              label: 'Trace id',
              value: error.traceId!,
              monospace: true,
            ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('retry-backend-button'),
            onPressed: controller.checkBackend,
            icon: const Icon(Icons.refresh),
            label: const Text('Check again'),
          ),
        ),
      ],
    );
  }

  Widget _noticeCard(BuildContext context) => SectionCard(
    title: 'Redirect return',
    icon: Icons.u_turn_left,
    children: <Widget>[
      Text(widget.controller.notice!),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: widget.controller.clearNotice,
          child: const Text('Dismiss'),
        ),
      ),
    ],
  );

  Widget _unresolvedCard(BuildContext context) => SectionCard(
    title: 'Unresolved payments from a previous run',
    icon: Icons.restore,
    subtitle:
        'UqpayPayments.reconcileUnresolved() ran at startup: every intent '
        'this app had pinned but never resolved was re-read from the server '
        'before you can start a new attempt.',
    children: <Widget>[
      for (final entry in widget.controller.unresolved)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ResultView(
            result: entry,
            onReconcile: widget.controller.reconcile,
          ),
        ),
    ],
  );

  Widget _orderCard(BuildContext context) {
    final controller = widget.controller;
    return SectionCard(
      title: 'The order',
      icon: Icons.receipt_long_outlined,
      subtitle:
          'The amount is a decimal string in MAJOR units and is forwarded '
          'byte-for-byte: "8.98" is 8 dollars 98, "898" is 898 yen. Nothing '
          'anywhere multiplies or divides it.',
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const Key('amount-field'),
                controller: _amount,
                onChanged: controller.setAmount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Amount (major units)',
                  border: const OutlineInputBorder(),
                  errorText: controller.parsedAmount == null
                      ? 'Not a decimal string'
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 130,
              child: DropdownButtonFormField<String>(
                key: const Key('currency-field'),
                initialValue: controller.currency,
                decoration: const InputDecoration(
                  labelText: 'Currency',
                  border: OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final currency in demoCurrencies)
                    DropdownMenuItem<String>(
                      value: currency.code,
                      child: Text(currency.code),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    controller.setCurrency(value);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LabelledValue(
          label: 'Formatted',
          value: controller.formattedAmount ?? '—',
        ),
        LabelledValue(
          label: 'On the wire',
          value: '"${controller.amount}" ${controller.currency}',
          monospace: true,
        ),
        Note(controller.currencyEntry.note, icon: Icons.calculate_outlined),
        const SizedBox(height: 12),
        TextField(
          key: const Key('description-field'),
          controller: _description,
          onChanged: controller.setDescription,
          decoration: const InputDecoration(
            labelText: 'Description',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _surfacesCard(BuildContext context) {
    final controller = widget.controller;
    final ready = controller.payments != null;
    return SectionCard(
      title: 'Two API surfaces, same payment',
      icon: Icons.call_split,
      subtitle:
          'The drop-in sheet is a consumer of the headless API. Anything the '
          'sheet does you can do yourself with UqpayPayments.',
      children: <Widget>[
        SegmentedButton<UqpaySheetPresentation>(
          key: const Key('presentation-switch'),
          segments: const <ButtonSegment<UqpaySheetPresentation>>[
            ButtonSegment<UqpaySheetPresentation>(
              value: UqpaySheetPresentation.methodList(),
              label: Text('Method list'),
            ),
            ButtonSegment<UqpaySheetPresentation>(
              value: UqpaySheetPresentation.cardOnly(),
              label: Text('Card only'),
            ),
            ButtonSegment<UqpaySheetPresentation>(
              value: UqpaySheetPresentation.singleWallet('alipaycn'),
              label: Text('Alipay only'),
            ),
          ],
          selected: <UqpaySheetPresentation>{_presentation},
          onSelectionChanged: (selection) =>
              setState(() => _presentation = selection.first),
        ),
        SwitchListTile(
          key: const Key('restrict-methods-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('allowedPaymentMethods: {card, alipaycn}'),
          subtitle: const Text(
            'Intersected with what the intent offers; other wallets are '
            'hidden from the list.',
          ),
          value: _restrictMethods,
          onChanged: (value) => setState(() => _restrictMethods = value),
        ),
        const SizedBox(height: 6),
        FilledButton.icon(
          key: const Key('pay-with-sheet-button'),
          onPressed: ready && controller.busy == null ? _payWithSheet : null,
          icon: const Icon(Icons.credit_card),
          label: const Text('Pay with the sheet'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const Note(
          'UqpayPaymentSheet.present(...) — one call, one typed result. Uses '
          'the host theme, plus the brand override when the palette icon in '
          'the app bar is on.',
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const Key('headless-button'),
          onPressed: ready ? _openHeadless : null,
          icon: const Icon(Icons.terminal),
          label: const Text('Headless checkout'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const Note(
          "The same payment driven by the app's own UI through "
          'UqpayPayments.createFlow / confirm, with the progress stream, '
          'cancel, pause and resume exposed.',
        ),
        if (!ready)
          const Note(
            'Both are disabled until the SDK initialises.',
            icon: Icons.info_outline,
          ),
      ],
    );
  }

  Widget _resultCard(BuildContext context) => SectionCard(
    title: 'Last result',
    icon: Icons.fact_check_outlined,
    children: <Widget>[
      ResultView(
        result: widget.controller.result!,
        onReconcile: widget.controller.reconcile,
      ),
    ],
  );

  Widget _truthCard(BuildContext context) => SectionCard(
    title: 'The client result is a UX signal, not proof of payment',
    icon: Icons.gpp_maybe_outlined,
    children: <Widget>[
      const Text(
        'Your server fulfils an order only after it retrieves the payment '
        'intent from UQPAY itself. A webhook is the prompt to do that read, '
        'not proof on its own — and what this screen says is never proof.',
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _openWebhooks,
          icon: const Icon(Icons.podcasts_outlined),
          label: const Text('Watch webhooks arrive'),
        ),
      ),
    ],
  );

  // ---------------------------------------------------------------- actions

  String get _platformLabel {
    if (kIsWeb) {
      return 'web';
    }
    return defaultTargetPlatform.name;
  }

  Future<void> _changeEnvironment(UqpayEnvironment target) async {
    if (target == UqpayEnvironment.production) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: const Text('Switch to PRODUCTION?'),
          content: const Text(
            'Production moves real money. The sample app is for sandbox '
            'testing; your backend must also be running with production '
            'credentials, and it refuses to unless UQPAY_ALLOW_PRODUCTION=1.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Stay on sandbox'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Use production'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }
    widget.controller.setEnvironment(target);
  }

  Future<void> _payWithSheet() async {
    final controller = widget.controller;
    final api = controller.payments;
    if (api == null) {
      return;
    }
    final intent = await controller.createIntent();
    if (intent == null || !mounted) {
      return;
    }
    final result = await UqpayPaymentSheet.present(
      context,
      payments: api,
      intentId: intent.id,
      returnUrl: controller.returnUrl,
      appearance: widget.theme.appearanceFor(context),
      presentation: _presentation,
      allowedPaymentMethods: _restrictMethods
          ? const <String>{'card', 'alipaycn'}
          : null,
    );
    if (!mounted) {
      return;
    }
    controller.setResult(result);
  }

  // Awaiting the route (rather than `unawaited(...)`) is the one form that is
  // lint-clean on both the floor Flutter (discarded_futures) and the newest
  // stable (unnecessary_unawaited, since Navigator.push is @awaitNotRequired).
  Future<void> _openHeadless() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            HeadlessPage(controller: widget.controller, theme: widget.theme),
      ),
    );
  }

  Future<void> _openWebhooks() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebhooksPage(controller: widget.controller),
      ),
    );
  }
}

class _ProductionBanner extends StatelessWidget {
  const _ProductionBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('production-banner'),
      width: double.infinity,
      color: scheme.error,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        'PRODUCTION — real money moves here.',
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(color: scheme.onError),
      ),
    );
  }
}
