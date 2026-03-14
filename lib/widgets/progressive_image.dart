import 'package:flutter/material.dart';

/// BlurHash → サムネイル → フル解像度の3段階ロードを行う画像ウィジェット。
class ProgressiveImage extends StatelessWidget {
  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;

  const ProgressiveImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    // TODO: 3段階ロードの実装
    return const Placeholder();
  }
}
