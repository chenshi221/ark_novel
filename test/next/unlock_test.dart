import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/pages/settings_page.dart';
import 'package:ark_novel/next/unlock.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';

class _Site implements HttpClientAdapter {
  _Site(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromBytes(const GbkCodec(allowInvalid: true).encode('<html><body><div id="content">$body</div></body></html>'), 200);

  @override
  void close({bool force = false}) {}
}

void main() {
  late ProviderContainer c;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_unlock_host_test').path);
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  setUp(() async {
    await Hive.box('session').clear();
    c = ProviderContainer();
  });

  tearDown(() => c.dispose());

  test('公开空壳与私有实现均可通过宿主边界正常编译与解析', () async {
    final s = c.read(unlockServiceProvider);
    expect(s.enabled, hasUnlockAddon);
    expect(isLockedContent(Content(text: '正文', images: const [])), isFalse);
    expect(isLockedContent(Content(text: '因版权问题，文库不再提供该小说的阅读！', images: const [])), hasUnlockAddon);

    const base = 'https://www.wenku8.net';
    final client = Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = _Site('正常正文'));
    final api = Api(client, Wenku8Urls(base, CharsetType.gbk), base, 'u1', unlock: s);
    expect((await api.chapter('15', '2')).text, '正常正文');
  });

  testWidgets('设置页直接显示「妙妙小工具」并按公开/私有模式展示对应内容', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsPage()),
      ),
    );
    expect(find.text('妙妙小工具'), findsOneWidget);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsSectionPage(section: SettingsSection.unlock)),
      ),
    );
    if (hasUnlockAddon) {
      expect(find.text('启用妙妙小工具'), findsOneWidget);
    } else {
      expect(find.textContaining('感兴趣的话，联系作者获取。'), findsOneWidget);
      expect(find.text('chenshi22150@gmail.com'), findsOneWidget);
    }
  });
}
