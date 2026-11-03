import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../data/wenku8/wenku8_app_api.dart';
import '../data/wenku8/wenku8_parser.dart';
import '../data/wenku8/wenku8_txt.dart';
import '../models/cat_volume.dart';
import '../models/content.dart';
import 'app_prefs.dart';
import 'cache.dart';
import 'history.dart';
import 'incognito.dart';
import 'library.dart';
import 'session.dart';
import 'txt_download.dart';

/// 受限章节：网页正文只剩「因版权问题，文库不再提供该小说的阅读！」，或者只有 `null`。
/// 空章节不算：正常书偶尔也有空章，不能因此去下整本 TXT。
bool isLockedContent(Content c) {
  if (c.images.isNotEmpty) return false;
  final t = c.text.trim();
  return t.toLowerCase() == 'null' || (t.length < 60 && t.contains('因版权问题'));
}

/// 受限章节在 App 接口和全本 TXT 里都没有（多半是插图章：TXT 不带图）。[message] 直接给读者看。
class ChapterLockedException implements Exception {
  const ChapterLockedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 受限书的正文：先问文库 App 接口（带插图），不行就把全本 TXT 按网站目录导入章节缓存，之后都从缓存读。
class UnlockService {
  UnlockService(this._ref);

  final Ref _ref;

  /// 同一本书同时要好几章（预加载、缓存全本）时只下载、导入一次
  final _importing = <String, Future<void>>{};

  bool get enabled => AppPrefs.read(P.unlock, true);

  bool get _apiEnabled => AppPrefs.read(P.unlockApi, true);

  static Box get _box => Hive.box('session');

  /// [catalogue] 网站目录：TXT 的章节标题就是「卷名 章名」，靠它对上 cid。
  Future<Content> chapter(String aid, String cid, Future<List<CatVolume>> Function() catalogue) async {
    if (_apiEnabled) {
      try {
        return await _ref.read(appApiProvider).chapter(aid, cid);
      } catch (_) {}
    }
    Future<Content?> cached() async {
      final c = await ChapterCache.get(aid, cid);
      return c == null || isLockedContent(c) ? null : c;
    }

    final done = await cached(); // 别的请求刚导入完
    if (done != null) return done;
    // 导入时记下 TXT 里有哪些章（m）、当时目录有哪些章（a）：
    // TXT 里本来就没有的（插图）别再下一遍；有过但缓存被清了、或导入后网站新出的章，重新导入
    final seen = _box.get('unlock:txt:$aid') as Map?;
    final had = (seen?['m'] as List?)?.contains(cid) ?? false;
    final known = (seen?['a'] as List?)?.contains(cid) ?? false;
    if (had || !known) {
      await (_importing[aid] ??= _import(aid, catalogue).whenComplete(() {
        _importing.remove(aid); // 箭头函数会把这个 Future 自己当返回值，whenComplete 等它就卡死了
      }));
      final c = await cached();
      if (c != null) return c;
    }
    throw const ChapterLockedException('本章受版权限制，全本 TXT 里也没有这一章（插图章节 TXT 不带图片）。');
  }

  Future<void> _import(String aid, Future<List<CatVolume>> Function() catalogue) async {
    final cat = await catalogue();
    final txt = Wenku8Txt.decode(await _ref.read(txtDownloaderProvider).fetch(aid));
    final texts = Wenku8Txt.byCatalogue(txt, cat);
    if (texts.isEmpty) throw const ChapterLockedException('全本 TXT 和网站目录对不上，取不到正文。');
    for (final MapEntry(key: cid, value: text) in texts.entries) {
      final ticket = ChapterCache.ticket(aid, cid);
      final old = await ChapterCache.get(aid, cid);
      if (old == null || isLockedContent(old)) await ChapterCache.put(aid, cid, Content(text: text, images: const []), ticket: ticket);
    }
    final all = [for (final v in cat) ...v.chapters];
    // 记成离线缓存：启动时的自动清理不会删，「离线缓存」里能看到、能删（无痕阅读时不记进离线缓存列表）
    if (!Incognito.on && !ChapterCache.offline(aid) && all.isNotEmpty) {
      final book = LibraryStore.get(aid);
      final seen = ReadingHistory.all().where((e) => e.aid == aid).firstOrNull; // 不在书架上就用阅读历史里的书名、封面
      final title = (book?['title'] as String?) ?? seen?.title ?? RegExp(r'^<([^<>\n]+)>$', multiLine: true).firstMatch(txt)?[1] ?? aid;
      final img = [book?['img'] as String?, seen?.img].whereType<String>().where((e) => e.isNotEmpty).firstOrNull ?? Wenku8Parser.coverUrl(aid);
      await ChapterCache.setMeta(aid, title, all.length, img, all.first.cid);
    }
    await _box.put('unlock:txt:$aid', {'m': texts.keys.toList(), 'a': [for (final c in all) c.cid]});
  }
}

final appApiProvider = Provider<Wenku8AppApi>((ref) {
  final store = ref.watch(sessionStoreProvider);
  ref.watch(proxyProvider);
  final dio = Dio(BaseOptions(responseType: ResponseType.bytes, connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 30)))
    ..httpClientAdapter = store.adapter();
  return Wenku8AppApi(dio: dio);
});

final unlockServiceProvider = Provider<UnlockService>((ref) => UnlockService(ref));
