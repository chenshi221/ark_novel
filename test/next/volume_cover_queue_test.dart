import 'dart:io';

import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/volumes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// 假接口：取插图章节一律失败，记下取了几次
class _FailingApi implements Api {
  int calls = 0;

  @override
  Future<Content> chapter(String aid, String cid) async {
    calls++;
    throw Exception('network');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('封面队列：连着失败 3 本就停，不把整个书架请求一遍', () async {
    final dir = await Directory.systemTemp.createTemp('vqueue');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    final box = await Hive.openBox('session');
    addTearDown(Hive.close);
    await ChapterCache.open();
    final aids = [for (var i = 0; i < 6; i++) '$i'];
    for (final aid in aids) {
      await box.put('vols:$aid', [
        {'t': '第一卷', 'c': ['c$aid'], 'i': 'i$aid'},
      ]);
    }
    final api = _FailingApi();
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);

    await c.read(volumeCoverQueueProvider).prefetchAll(aids);

    expect(api.calls, 3);
  });
}
