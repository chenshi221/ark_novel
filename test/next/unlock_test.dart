import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_app_api.dart';
import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/txt_download.dart';
import 'package:ark_novel/next/unlock.dart';
import 'package:hive_ce/hive.dart';

/// 假的 App 接口：挂了，或者返回带图的正文。
class _FakeApi implements Wenku8AppApi {
  _FakeApi({this.fail = true});

  final bool fail;

  @override
  Future<List<CatVolume>> catalogue(String aid) async => throw const Wenku8AppApiException('接口不可用');

  @override
  Future<Content> chapter(String aid, String cid) async {
    if (fail) throw const Wenku8AppApiException('接口不可用');
    return Content(text: '接口正文 $cid', images: const ['https://img/1.jpg']);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假的 TXT 下载器：返回 OVERLORD 片段（GBK），记下载了几次。
class _FakeTxt implements TxtDownloader {
  int fetches = 0;

  @override
  Future<Uint8List> fetch(String aid) async {
    fetches++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final text = File('test/data/wenku8/fixtures/txt_book.txt').readAsStringSync();
    return Uint8List.fromList(const GbkCodec(allowInvalid: true).encode(text));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 网站的章节页：正文就是 [body]。
class _Site implements HttpClientAdapter {
  _Site(this.body);

  String body;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromBytes(const GbkCodec(allowInvalid: true).encode('<html><body><div id="content">$body</div></body></html>'), 200);

  @override
  void close({bool force = false}) {}
}

CatVolume vol(String title, Map<String, String> chapters) => CatVolume(title: title, chapters: [for (final e in chapters.entries) CatChapter(title: e.value, cid: e.key)]);

final testCat = [
  vol('第一卷', {'1': 'prologue', '2': '第一章 开始与结束', '3': '第二章 楼层守护者', '4': 'EPILOGUE', '5': '后记', '6': '插图'}),
  vol('第二卷 黑暗战士', {'7': 'prologue', '8': '第一章 两个冒险者', '9': 'EPILOGUE', '10': '后记', '11': '插图'}),
];

Future<List<CatVolume>> cat() async => testCat;

void main() {
  late _FakeTxt txt;
  late ProviderContainer c;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_unlock_test').path);
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  setUp(() async {
    await Hive.box('session').clear();
    await Hive.box('session').put('p.unlock.enabled', true);
    txt = _FakeTxt();
    c = ProviderContainer(overrides: [appApiProvider.overrideWithValue(_FakeApi()), txtDownloaderProvider.overrideWithValue(txt)]);
  });

  tearDown(() => c.dispose());

  test('认得受限提示；空章节、普通正文不算', () {
    expect(isLockedContent(Content(text: '因版权问题，文库不再提供该小说的阅读！', images: const [])), isTrue);
    expect(isLockedContent(Content(text: ' null ', images: const [])), isTrue);
    expect(isLockedContent(Content(text: '', images: const [])), isFalse);
    expect(isLockedContent(Content(text: '正文', images: const [])), isFalse);
    expect(isLockedContent(Content(text: 'null', images: const ['x'])), isFalse);
  });

  test('接口挂了：整本 TXT 按网站 cid 导入，同时要几章也只下载一次，记成离线缓存', () async {
    final s = c.read(unlockServiceProvider);
    final got = await Future.wait([s.chapter('10', '2', cat), s.chapter('10', '3', cat)]);
    expect(got[0].text, startsWith('１\n这个名词是'));
    expect(got[1].text, isNotEmpty);
    expect(txt.fetches, 1);
    expect(ChapterCache.has('10', '1'), isTrue);
    expect(ChapterCache.offline('10'), isTrue);
  });

  test('插图章：TXT 里没有，抛 ChapterLockedException，也不再重新下载', () async {
    final s = c.read(unlockServiceProvider);
    await s.chapter('11', '1', cat);
    await expectLater(s.chapter('11', '6', cat), throwsA(isA<ChapterLockedException>()));
    expect(txt.fetches, 1);
  });

  test('缓存被清了、或者是导入后新出的章：重新导入', () async {
    final s = c.read(unlockServiceProvider);
    await s.chapter('12', '1', cat);
    await ChapterCache.remove('12');
    await s.chapter('12', '2', cat);
    expect(txt.fetches, 2);
  });

  test('以前存下的受限提示会被 TXT 正文替换，真正文不动', () async {
    await ChapterCache.put('13', '2', Content(text: '因版权问题，文库不再提供该小说的阅读！', images: const []));
    await ChapterCache.put('13', '3', Content(text: '以前缓存的真正文', images: const ['a.jpg']));
    await c.read(unlockServiceProvider).chapter('13', '1', cat);
    expect((await ChapterCache.get('13', '2'))!.text, startsWith('１'));
    expect((await ChapterCache.get('13', '3'))!.text, '以前缓存的真正文');
  });

  test('接口能用时直接用接口（带插图），不下载 TXT', () async {
    final c2 = ProviderContainer(overrides: [appApiProvider.overrideWithValue(_FakeApi(fail: false)), txtDownloaderProvider.overrideWithValue(txt)]);
    addTearDown(c2.dispose);
    final got = await c2.read(unlockServiceProvider).chapter('14', '6', cat);
    expect(got.images, ['https://img/1.jpg']);
    expect(txt.fetches, 0);
  });

  group('Api.chapter', () {
    const base = 'https://www.wenku8.net';
    Api api(_Site site) {
      final client = Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = site);
      return _CatApi(client, Wenku8Urls(base, CharsetType.gbk), base, 'u1', unlock: c.read(unlockServiceProvider));
    }

    test('正常正文、没开解锁时原样返回；开了解锁遇到受限提示自动取正文', () async {
      expect((await api(_Site('正常正文')).chapter('15', '2')).text, '正常正文');
      await Hive.box('session').put('p.unlock.enabled', false);
      expect((await api(_Site('因版权问题，文库不再提供该小说的阅读！')).chapter('15', '2')).text, contains('因版权问题'));
      expect(txt.fetches, 0);
      await Hive.box('session').put('p.unlock.enabled', true);
      expect((await api(_Site('因版权问题，文库不再提供该小说的阅读！')).chapter('15', '2')).text, startsWith('１'));
    });
  });
}

/// 目录不联网，直接给测试目录
class _CatApi extends Api {
  _CatApi(super.client, super.urls, super.base, super.scope, {super.unlock});

  @override
  Future<List<CatVolume>> catalogue(String aid) async => testCat;
}
