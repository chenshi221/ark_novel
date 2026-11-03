import 'package:hive_ce_flutter/hive_flutter.dart';

import 'cache.dart';
import 'history.dart';
import 'incognito.dart';
import 'library.dart';
import 'sync.dart';

/// 阅读统计：按天和按书累计阅读秒数，以及读过的章节数（同一章同一天只算一次）。
class ReadingStats {
  ReadingStats._();

  static Box get _box => Hive.box('session');

  static String dayKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Map<String, int> _map(String key) => ((_box.get(key) as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as int));

  /// 本机的统计加上同步来的其他设备的统计。[key] 是 day / book。
  static Map<String, int> _total(String key) {
    final out = _map('stats:$key');
    for (final s in Sync.otherStats()) {
      for (final e in ((s[key] as Map?) ?? const {}).entries) {
        out['${e.key}'] = (out['${e.key}'] ?? 0) + (e.value as int);
      }
    }
    return out;
  }

  /// 日期 → 秒
  static Map<String, int> perDay() => _total('day');

  /// aid → 秒
  static Map<String, int> perBook() => _total('book');

  static int get chapters => ((_box.get('stats:chapters') as int?) ?? 0) + Sync.otherStats().fold(0, (a, s) => a + ((s['chapters'] as int?) ?? 0));

  /// 读过这本书的日期（`yyyy-MM-dd`，去重）
  static List<String> bookDays(String aid) => {
    ...((_box.get('stats:days:$aid') as List?) ?? const []).cast<String>(),
    for (final s in Sync.otherStats()) ...(((s['days'] as Map?)?[aid] as List?) ?? const []).cast<String>(),
  }.toList()..sort();

  /// 书的信息（标题、作者、封面），统计页和阅读报告用。
  static ({String title, String author, String img})? meta(String aid) {
    final m = (_box.get('stats:meta') as Map?)?[aid] ?? Sync.otherStats().map((s) => (s['meta'] as Map?)?[aid]).whereType<Map>().firstOrNull;
    return m is Map ? (title: m['t'] as String, author: (m['a'] as String?) ?? '', img: (m['i'] as String?) ?? '') : null;
  }

  /// 书名、作者、封面：统计里记的没有时（例如离线时读的），依次从本地书架、阅读历史、离线缓存里找；都没有才显示书号。
  static ({String title, String author, String img}) info(String aid) {
    final m = meta(aid);
    if (m != null && m.title.isNotEmpty) return (title: LibraryStore.shown(aid, m.title), author: m.author, img: m.img);
    final lib = LibraryStore.get(aid);
    final hist = ReadingHistory.all().where((e) => e.aid == aid).firstOrNull;
    final cached = ChapterCache.books()[aid];
    final title = (lib?['title'] as String?) ?? hist?.title ?? cached?.$1;
    final img = [m?.img, lib?['img'] as String?, hist?.img, cached?.$3].whereType<String>().where((e) => e.isNotEmpty).firstOrNull ?? '';
    return (title: LibraryStore.shown(aid, title ?? '书号 $aid'), author: m?.author ?? '', img: img);
  }

  static Future<void> setMeta(String aid, String title, String author, String img) async {
    if (Incognito.on) return;
    final all = Map.of((_box.get('stats:meta') as Map?) ?? const {});
    all[aid] = {'t': title, 'a': author, 'i': img};
    await _box.put('stats:meta', all);
  }

  static Map<String, Map<String, int>> _localChapterSeconds(String aid) => ((_box.get('stats:ch:$aid') as Map?) ?? const {}).map(
    (k, v) => MapEntry(k as String, (v as Map).map((d, s) => MapEntry(d as String, s as int))),
  );

  /// 每章每天读了多少秒：cid → 日期 → 秒。按卷统计时长、天数用（这个功能加上之后才开始记）。
  static Map<String, Map<String, int>> chapterSeconds(String aid) {
    final out = _localChapterSeconds(aid);
    for (final s in Sync.otherStats()) {
      final ch = (s['ch'] as Map?)?[aid];
      if (ch is! Map) continue;
      for (final ce in ch.entries) {
        if (ce.value is! Map) continue;
        final days = out['${ce.key}'] ??= {};
        for (final de in (ce.value as Map).entries) {
          if (de.value is int) days['${de.key}'] = (days['${de.key}'] ?? 0) + (de.value as int);
        }
      }
    }
    return out;
  }

  /// 读过的书 aid（按章记过时长的）
  static Iterable<String> chapterBooks() => {
    ..._box.keys.whereType<String>().where((k) => k.startsWith('stats:ch:')).map((k) => k.substring(9)),
    for (final s in Sync.otherStats()) ...(((s['ch'] as Map?) ?? const {}).keys.map((k) => '$k')),
  };

  /// 日期满足 [inDay] 的那些天里，每本书读了多少秒：aid → 秒。按章记的时长合计，只有本机的、这个功能加上之后的。
  static Map<String, int> booksOn(bool Function(String day) inDay) => {
    for (final aid in chapterBooks())
      if (chapterSeconds(aid).values.expand((d) => d.entries).where((e) => inDay(e.key)).fold(0, (a, e) => a + e.value) case final s when s > 0) aid: s,
  };

  /// 删掉一本书的阅读记录，同步时其他设备也删。累计章数没有按书记，不变。
  static Future<void> deleteBook(String aid) async {
    await purgeLocal(aid);
    await Sync.forgetBookStats(aid);
  }

  /// 删掉本机记的这本书。每天的时长只能减去按章记过的部分（这个功能加上之前的不知道属于哪本书）。
  static Future<void> purgeLocal(String aid) async {
    final day = _map('stats:day');
    for (final days in _localChapterSeconds(aid).values) {
      for (final e in days.entries) {
        final left = (day[e.key] ?? 0) - e.value;
        left > 0 ? day[e.key] = left : day.remove(e.key);
      }
    }
    final meta = Map.of((_box.get('stats:meta') as Map?) ?? const {})..remove(aid);
    await _box.putAll({'stats:day': day, 'stats:book': _map('stats:book')..remove(aid), 'stats:meta': meta});
    await _box.deleteAll(['stats:days:$aid', 'stats:ch:$aid']);
  }

  static Future<void> addSeconds(String aid, int seconds, {String? cid}) async {
    if (seconds <= 0 || Incognito.on) return;
    final today = dayKey(DateTime.now());
    if (cid != null) {
      final ch = _localChapterSeconds(aid);
      final days = ch[cid] ??= {};
      days[today] = (days[today] ?? 0) + seconds;
      await _box.put('stats:ch:$aid', ch);
    }
    final days = ((_box.get('stats:days:$aid') as List?) ?? const []).cast<String>();
    if (!days.contains(today)) await _box.put('stats:days:$aid', [...days, today]);
    final day = _map('stats:day'); // 只累加本机自己的，别的设备的统计单独存放
    final book = _map('stats:book');
    day[today] = (day[today] ?? 0) + seconds;
    book[aid] = (book[aid] ?? 0) + seconds;
    await _box.put('stats:day', day);
    await _box.put('stats:book', book);
  }

  static Future<void> addChapter(String aid, String cid) async {
    if (Incognito.on) return;
    final today = dayKey(DateTime.now());
    final seen = ((_box.get('stats:seen') as List?) ?? const []).cast<String>();
    final key = '$today:$aid:$cid';
    if (seen.contains(key)) return;
    await _box.put('stats:seen', [...seen.where((e) => e.startsWith(today)), key]);
    await _box.put('stats:chapters', ((_box.get('stats:chapters') as int?) ?? 0) + 1);
  }
}
