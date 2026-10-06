/// Screen-reader announcements for the sheet. Internal.
library;

import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Announces [message] to the platform's screen reader (TalkBack /
/// VoiceOver), using the view and text direction of [context].
void announceForAccessibility(BuildContext context, String message) {
  unawaited(
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    ),
  );
}
