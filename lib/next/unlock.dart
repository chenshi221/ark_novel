import 'package:ark_unlock/ark_unlock.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../data/wenku8/wenku8_parser.dart';
import '../models/cat_volume.dart';
import '../models/content.dart';
import 'app_prefs.dart';
import 'cache.dart';
import 'history.dart';
import 'incognito.dart';
import 'library.dart';
import 'session.dart';

export 'package:ark_unlock/ark_unlock.dart' show ChapterLockedException, hasUnlockAddon;

bool isLockedContent(Content c) => isLockedContentText(c.text, c.images);

/// 宿主对可选扩展组件 [UnlockAddon] 的适配层：公开仓库只含空壳，本机通过 `pubspec_overrides.yaml` 挂载完整实现。
class UnlockService implements UnlockHost {
  UnlockService(this._ref);

  final Ref _ref;
  final _catalogues = <String, Future<List<CatVolume>> Function()>{};
  late final UnlockAddon _addon = UnlockAddon(this);

  static Box get _box => Hive.box('session');

  @override
  bool get enabled => hasUnlockAddon && AppPrefs.read(P.unlock, true);

  @override
  bool get apiEnabled => AppPrefs.read(P.unlockApi, true);

  @override
  bool get incognito => Incognito.on;

  @override
  Dio createAppDio() {
    final store = _ref.read(sessionStoreProvider);
    _ref.read(proxyProvider);
    return Dio(BaseOptions(responseType: ResponseType.bytes, connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 30)))
      ..httpClientAdapter = store.adapter();
  }

  @override
  Dio createTxtDio() {
    final store = _ref.read(sessionStoreProvider);
    _ref.read(proxyProvider);
    return Dio(
      BaseOptions(
        responseType: ResponseType.bytes,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 120),
        headers: {'User-Agent': store.userAgent, 'Accept': '*/*'},
      ),
    )..httpClientAdapter = store.adapter();
  }

  @override
  Future<UnlockContent?> getCache(String aid, String cid) async {
    final c = await ChapterCache.get(aid, cid);
    return c == null ? null : UnlockContent(c.text, c.images);
  }

  @override
  Future<void> putCache(String aid, String cid, UnlockContent content, {Object? ticket}) =>
      ChapterCache.put(aid, cid, Content(text: content.text, images: content.images), ticket: ticket as (int, int)?);

  @override
  (int, int) ticket(String aid, String cid) => ChapterCache.ticket(aid, cid);

  @override
  Map? getSeen(String aid) => _box.get('unlock:txt:$aid') as Map?;

  @override
  Future<void> putSeen(String aid, Map seen) => _box.put('unlock:txt:$aid', seen);

  @override
  Future<List<UnlockVolumeRef>> fetchCatalogue(String aid) async {
    final cat = await (_catalogues[aid]!)();
    return [
      for (final v in cat)
        (title: v.title, chapters: [for (final c in v.chapters) (cid: c.cid, title: c.title)]),
    ];
  }

  @override
  Future<void> saveOfflineMeta(String aid, String? parsedTitle, int total, String firstCid) async {
    if (ChapterCache.offline(aid)) return;
    final book = LibraryStore.get(aid);
    final seen = ReadingHistory.all().where((e) => e.aid == aid).firstOrNull;
    final name = (book?['title'] as String?) ?? seen?.title ?? parsedTitle ?? aid;
    final img = [book?['img'] as String?, seen?.img].whereType<String>().where((e) => e.isNotEmpty).firstOrNull ?? Wenku8Parser.coverUrl(aid);
    await ChapterCache.setMeta(aid, name, total, img, firstCid);
  }

  Future<Content> chapter(String aid, String cid, Future<List<CatVolume>> Function() catalogue) async {
    _catalogues[aid] = catalogue;
    final got = await _addon.chapter(aid, cid);
    return Content(text: got.text, images: got.images);
  }

  Future<String> testApi() => _addon.testApi();
}

final unlockServiceProvider = Provider<UnlockService>((ref) => UnlockService(ref));
