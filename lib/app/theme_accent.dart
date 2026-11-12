import 'package:flutter/material.dart';

/// Curated, muted accents. Names are stable IDs for the saved preference.
enum ThemeAccent {
  forest('松柏绿', Color(0xff25664c)),
  mist('雾霭蓝', Color(0xff496780)),
  lilac('丁香紫', Color(0xff716081)),
  rose('玫瑰灰', Color(0xff8a5b6a)),
  sand('暖沙棕', Color(0xff80674b)),
  graphite('石墨灰', Color(0xff59666b));

  const ThemeAccent(this.label, this.seed);

  final String label;
  final Color seed;
}
