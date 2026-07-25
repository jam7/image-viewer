import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

final _log = Logger('HostActivity');

/// The Android activity the app runs inside, for the few things only it can do.
///
/// Flutter draws the whole screen, but the activity, the task and the back
/// stack still belong to the platform. Flutter wraps some of that — most
/// visibly `SystemNavigator.pop()` — and not the rest, which is what this is
/// for. See [moveToBackground].
class HostActivity {
  static const _channel = MethodChannel('app/activity');

  const HostActivity();

  /// Leave the app without ending it, the way pressing back at the root of
  /// Chrome does: the activity stays alive, so coming straight back shows
  /// everything exactly as it was.
  ///
  /// `SystemNavigator.pop()` cannot be used for this — it is `finish()`, which
  /// destroys the activity and takes every open tab and its history with it.
  /// That is also why this matters here: the tab set lives in memory, so the
  /// difference between backgrounding and finishing is the difference between
  /// resuming and starting over. (A restore from disk is the durable answer and
  /// is still to come; this is the fast path that covers the everyday case.)
  ///
  /// Android only. Nowhere else has a system back gesture that reaches here, so
  /// elsewhere this is simply not asked for.
  Future<void> moveToBackground() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('moveToBackground');
    } on MissingPluginException catch (e) {
      // The channel is matched by name at runtime, so a host that does not
      // implement it says so here rather than at build time.
      _log.info('moveToBackground unavailable on this host', e);
    }
  }
}
