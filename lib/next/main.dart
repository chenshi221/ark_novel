import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'cache.dart';
import 'fonts.dart';
import 'session.dart';
import 'settings.dart';

/// App 入口（lib/main.dart 只是转到这里）。
///
/// - 原生：`flutter run -t lib/next/main.dart`
/// - 网页预览：`flutter run -d web-server -t lib/next/main.dart`，并在同一台机器上运行 `tool/preview_proxy.dart`
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 解码好的封面多留一些（默认 100 MB），滑回去不用重新解码
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20;
  final store = await SessionStore.open();
  // 字体在后台加载，不挡着第一帧（阅读页用自选字体时会等它，见 FontStore.ready）
  FontStore.loadSaved().ignore();
  await ChapterCache.open();
  applyOrientation(OrientationController.saved);
  // 不用 Riverpod 默认的自动重试：失败的请求自己重复十次只会加快被 Cloudflare 限流
  runApp(ProviderScope(retry: (_, _) => null, overrides: [sessionStoreProvider.overrideWithValue(store)], child: const NextApp()));
}
