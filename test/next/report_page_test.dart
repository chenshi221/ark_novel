import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/pages/report_page.dart';

void main() {
  testWidgets('阅读报告能正常排版（之前 stretch 在滚动区域里整页布局失败，只剩背景色）', (tester) async {
    Hive.init(Directory.systemTemp.createTempSync('ark_report_test').path);
    await tester.runAsync(() async {
      await Hive.openBox('session');
      await ChapterCache.open();
    });
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: ReportPage(aid: '1'))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('阅读时间'), findsOneWidget);
    expect(find.text('已读天数'), findsOneWidget);
  });
}
