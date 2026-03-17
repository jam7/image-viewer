import 'package:flutter/widgets.dart';

const galleryCrossAxisCount = 3;
const gallerySpacing = 4.0;

const galleryGridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: galleryCrossAxisCount,
  crossAxisSpacing: gallerySpacing,
  mainAxisSpacing: gallerySpacing,
);
