import '../../models/image_source.dart';
import '../sources/image_source_provider.dart';
import '../cache/memory_cache.dart';

/// スライディングウィンドウ方式でプリフェッチを制御する。
/// 前方3〜5枚、後方1〜2枚をキャッシュに保持。
class PrefetchManager {
  final ImageSourceProvider provider;
  final MemoryCache memoryCache;
  final int prefetchAhead;
  final int keepBehind;

  PrefetchManager({
    required this.provider,
    required this.memoryCache,
    this.prefetchAhead = 3,
    this.keepBehind = 2,
  });

  /// 現在の表示位置が変わった時に呼ぶ。
  /// 前後の画像をプリフェッチし、範囲外をキャッシュから排出する。
  Future<void> onPositionChanged(int currentIndex, List<ImageSource> images) async {
    // TODO: 実装
  }

  void dispose() {
    // TODO: 実行中のプリフェッチをキャンセル
  }
}
