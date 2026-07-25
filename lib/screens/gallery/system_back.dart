import 'package:flutter/widgets.dart';

import '../../services/platform/host_activity.dart';
import 'gallery_tab.dart';

/// What the system back gesture means, for every body that hosts one.
///
/// Two bodies answer it — `GalleryView` for the grids, `HomeGalleryBody` for
/// the landing page, which does not go through the view — and the answer has
/// to be the same in both: walk [tab]'s history, and once there is none left,
/// leave the app without ending it (ADR 009 追記).
///
/// [onStepped] is what the caller has to do about the move it did not make
/// itself; the bodies differ there and only there.
void handleSystemBack(GalleryTab tab, VoidCallback onStepped) {
  if (tab.back()) {
    onStepped();
    return;
  }
  // Not a route pop: popping the root is finish(), which destroys the
  // activity and every open tab with it.
  const HostActivity().moveToBackground();
}
