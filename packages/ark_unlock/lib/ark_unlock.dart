import 'package:dio/dio.dart';

/// 受限章节无法读取时抛出的异常（如公开构建未包含解锁组件，或插图章节在 TXT 中无正文）。
class ChapterLockedException implements Exception {
  const ChapterLockedException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UnlockContent {
  const UnlockContent(this.text, this.images);

  final String text;
  final List<String> images;
}

typedef UnlockChapterRef = ({String cid, String title});
typedef UnlockVolumeRef = ({String title, List<UnlockChapterRef> chapters});

/// 宿主应用（ark_novel）提供给本地解锁组件的回调边界，避免反向依赖主工程。
abstract interface class UnlockHost {
  bool get enabled;
  bool get apiEnabled;
  bool get incognito;

  Dio createAppDio();
  Dio createTxtDio();

  Future<UnlockContent?> getCache(String aid, String cid);
  Future<void> putCache(String aid, String cid, UnlockContent content, {Object? ticket});
  (int, int) ticket(String aid, String cid);

  Map? getSeen(String aid);
  Future<void> putSeen(String aid, Map seen);

  Future<List<UnlockVolumeRef>> fetchCatalogue(String aid);
  Future<void> saveOfflineMeta(String aid, String? parsedTitle, int total, String firstCid);
}

/// 公开仓库中固定为 false；本机通过 `pubspec_overrides.yaml` 替换为私有实现后为 true。
const bool hasUnlockAddon = false;

bool isLockedContentText(String text, List<String> images) => false;

class UnlockAddon {
  UnlockAddon(this.host);

  final UnlockHost host;

  bool get enabled => false;

  Future<UnlockContent> chapter(String aid, String cid) => Future.error(const ChapterLockedException('本章受版权限制，公开版本不包含解锁组件。'));

  Future<String> testApi() async => '公开版本不包含解锁组件。';
}
