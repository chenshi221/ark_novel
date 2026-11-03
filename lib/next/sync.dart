import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_prefs.dart';
import 'avatar.dart';
import 'library.dart';
import 'settings.dart';
import 'stats.dart';
import 'updates.dart';
import 'volumes.dart';

/// 同步：每台设备把自己的数据整份写成 `<文件夹>/<设备ID>.json` 放到 WebDAV（坚果云），
/// 同步时读取其他设备的文件，按下面的规则并入本机。不依赖服务端，只要能 GET / PUT / PROPFIND。
///
/// 合并规则（都是幂等的，重复同步不会翻倍）：
/// - 阅读进度：按时间，新的赢
/// - 阅读历史：每本书取最近一次；书签：同一章 40 字以内视为同一个，取较新的；规则：按编号并集，本机优先
/// - 已读章节：并集；已读字数、评分：取较大 / 本机没有才用对方的；备注：并集，本机优先
/// - 书签、规则的删除靠"墓碑"同步（编号 → 删除时间，留 90 天）；规则的修改按修改时间，新的赢
/// - 阅读统计：其他设备的统计**单独存放**，显示时和本机相加，所以两边同时读也不会互相覆盖
///
/// shortcut: 备注的删除和修改不同步（本机优先），书签的墓碑按精确偏移匹配；需要时再给备注加时间。
/// shortcut: 设置（字号、主题等）不同步，每台设备外观习惯本来就不一样。
class Sync {
  Sync._();

  static Box get _box => Hive.box('session');

  /// 同步合并完成时通知界面刷新（书架、分类、封面、头像、偏好等）
  static final changes = ValueNotifier<int>(0);

  static const _secure = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false)); // 没开发者签名的 Mac 版用不了新式钥匙串（-34018）

  static String get url => (_box.get('sync:url') as String?) ?? 'https://dav.jianguoyun.com/dav/';
  static String get user => (_box.get('sync:user') as String?) ?? '';
  static const defaultFolder = 'ArkNovel';
  static String get folder => (_box.get('sync:folder') as String?) ?? defaultFolder;
  static int get lastSync => (_box.get('sync:last') as int?) ?? 0;
  static bool get configured => user.isNotEmpty;

  static bool get _useLocalPass => kIsWeb || Platform.isMacOS;

  /// 应用密码：安卓/iOS 放系统安全存储；Mac 版（无开发者证书签名访问钥匙串会反复弹窗要密码）直接存沙盒本地库。
  static Future<String> password() async {
    if (_useLocalPass) {
      final local = _box.get('sync:pass') as String?;
      if (local != null || _box.get('sync:passMoved') == true) return local ?? '';
      // 旧版存在钥匙串里的搬过来，只试一次，免得反复弹窗
      await _box.put('sync:passMoved', true);
      try {
        final old = await _secure.read(key: 'syncPass');
        if (old != null) await _box.put('sync:pass', old);
        return old ?? '';
      } catch (_) {
        return '';
      }
    }
    try {
      final p = await _secure.read(key: 'syncPass');
      if (p != null) return p;
    } catch (_) {}
    return (_box.get('sync:pass') as String?) ?? '';
  }

  static Future<void> save({required String url, required String user, required String pass, required String folder}) async {
    await _box.putAll({'sync:url': url.trim(), 'sync:user': user.trim(), 'sync:folder': folder.trim().isEmpty ? defaultFolder : folder.trim()});
    if (_useLocalPass) {
      await _box.put('sync:pass', pass);
      return;
    }
    try {
      await _secure.write(key: 'syncPass', value: pass);
      await _box.delete('sync:pass');
    } catch (_) {
      await _box.put('sync:pass', pass);
    }
  }

  static const _tombDays = 90;

  static Map<String, int> _tombs() => Map<String, int>.from((_box.get('sync:tomb') as Map?) ?? const {});

  /// 记下被删掉的东西（`b:书:章:偏移`、`r:规则编号`），同步时告诉其他设备也删掉。
  static Future<void> tombstone(Iterable<String> keys) async {
    if (keys.isEmpty) return;
    final t = _tombs();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final k in keys) {
      t[k] = now;
    }
    await _box.put('sync:tomb', t);
  }

  static String bookmarkKey(Map b) => 'b:${b['aid']}:${b['cid']}:${b['offset']}';

  static String get deviceId {
    var id = _box.get('sync:device') as String?;
    if (id == null) {
      id = 'd${Random.secure().nextInt(1 << 32).toRadixString(36)}${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      _box.put('sync:device', id);
    }
    return id;
  }

  // ---- 本机数据 → 快照 ----

  static Iterable<String> _keys(String prefix) => _box.keys.whereType<String>().where((k) => k.startsWith(prefix));

  /// 书架和更新偏好里跨设备同步的：列数、上次停在的标签各设备自己的。
  static bool _isShelfPref(String k) => (k.startsWith('p.shelf.') || k.startsWith('p.upd.')) && !{P.colsPortrait, P.colsLandscape, P.lastTab}.any((x) => k == 'p.$x');

  /// 头像图片不进快照：单独传成 `<设备ID>.avatar`，变了才传；快照里只记时间和文件名。
  static Map<String, dynamic>? _avatarSnapshot() {
    if (kIsWeb || !AppPrefs.read(P.syncAvatar, true)) return null;
    final path = _box.get('avatar') as String?;
    final ts = _box.get('avatar:ts') as int?;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (file.existsSync()) return {'ts': ts ?? file.lastModifiedSync().millisecondsSinceEpoch, 'ext': p.extension(path), 'file': '$deviceId.avatar'};
    }
    return ts == null ? null : {'ts': ts};
  }

  static Future<void> _pushAvatar(Dio dio) async {
    final a = _avatarSnapshot();
    if (a == null || a['file'] == null || _box.get('sync:avatarUp') == a['ts']) return;
    final bytes = await File(_box.get('avatar') as String).readAsBytes();
    _ok(await dio.put('${_dir()}${a['file']}', data: Stream.fromIterable([bytes]), options: Options(contentType: 'application/octet-stream', headers: {Headers.contentLengthHeader: bytes.length})), '上传头像');
    await _box.put('sync:avatarUp', a['ts']);
  }

  /// 对方的头像比本机新才下载，放进快照交给 [merge]；下载失败就当没变，下次再试。
  static Future<void> _pullAvatar(Dio dio, Map<String, dynamic> remote) async {
    final a = remote['avatar'];
    if (kIsWeb || !AppPrefs.read(P.syncAvatar, true) || a is! Map || a['file'] is! String) return;
    if (((a['ts'] as int?) ?? 0) <= ((_box.get('avatar:ts') as int?) ?? 0)) return;
    try {
      final r = await dio.get<List<int>>('${_dir()}${Uri.encodeComponent(p.basename(a['file'] as String))}', options: Options(responseType: ResponseType.bytes));
      _ok(r, '下载头像');
      a['data'] = base64Encode(r.data!);
    } catch (_) {
      remote.remove('avatar');
    }
  }

  /// 本机要同步的数据（不含从别的设备并入的统计）。
  static Map<String, dynamic> snapshot() {
    Map<String, dynamic> byAid(String prefix) => {for (final k in _keys(prefix)) k.substring(prefix.length): _box.get(k)};
    final avatar = _avatarSnapshot();
    return {
      'v': 3,
      'device': deviceId,
      'at': DateTime.now().millisecondsSinceEpoch,
      'progress': byAid('progress:'),
      'history': _box.get('history2') ?? const [],
      'bookmarks': _box.get('bookmarks') ?? const [],
      'read': byAid('read:'),
      'readchars': byAid('readchars:'),
      'rating': byAid('rating:'),
      'vrate': byAid('vrate:'),
      'rules': _box.get('rules') ?? const [],
      'notes': byAid('notes:'),
      'tomb': _tombs(),
      'books': _box.get('lib:books') ?? const {},
      'cats': _box.get('lib:cats') ?? const [],
      'shelfTabOrder': _box.get('shelfTabOrder'),
      'shelfOrder': byAid('shelfOrder:'),
      'vcover': byAid('vcover2:'),
      'vpick': byAid('vpick:'),
      'vpickTs': byAid('vpickTs:'),
      'vols': byAid('vols:'),
      'updates': {
        'feed': _box.get('updates') ?? const [],
        'known': _box.get('updates:known') ?? const {},
        'seen': _box.get('updates:seen') ?? 0,
        'at': byAid('updates:at:'),
      },
      'avatar': ?avatar,
      'shelfPrefs': {
        'ts': (_box.get('sync:prefsTs') as int?) ?? 0,
        'shelfOpts': _box.get('shelfOpts'),
        'p': {
          for (final k in _keys('p.'))
            if (_isShelfPref(k)) k: _box.get(k),
        },
      },
      'readerPrefs': {
        'ts': (_box.get('sync:readerTs') as int?) ?? 0,
        'r': {for (final k in _keys('r.')) k: _box.get(k)},
        'volumeDone': _box.get('p.${P.volumeDone}'),
      },
      'appearance': {
        'ts': (_box.get('sync:appearanceTs') as int?) ?? 0,
        'themeMode': _box.get('themeMode'),
        'palette': _box.get('palette'),
        'p': {for (final k in _keys('p.ui.')) k: _box.get(k)},
      },
      'stats': {
        'day': _box.get('stats:day') ?? const {},
        'book': _box.get('stats:book') ?? const {},
        'chapters': _box.get('stats:chapters') ?? 0,
        'meta': _box.get('stats:meta') ?? const {},
        'days': byAid('stats:days:'),
        'ch': byAid('stats:ch:'),
        'last': _box.get('stats:last') ?? const {},
      },
    };
  }

  // ---- 其他设备的快照 → 并入本机 ----

  static List<Map> _maps(Object? v) => [for (final e in (v as List?) ?? const []) Map<String, dynamic>.from(e as Map)];

  /// 把 [remote]（别的设备的快照，已解码的 JSON）按规则并入本机。
  static Future<void> merge(Map<String, dynamic> remote) async {
    if (remote['device'] == deviceId) return;
    final puts = <String, Object?>{};

    // 墓碑：取较新的删除时间，超过 90 天的丢掉；比删除时间旧的东西视为已删
    final tomb = _tombs();
    for (final e in ((remote['tomb'] as Map?) ?? const {}).entries) {
      if ((e.value as int) > (tomb[e.key] ?? 0)) tomb['${e.key}'] = e.value as int;
    }
    final cutoff = DateTime.now().millisecondsSinceEpoch - const Duration(days: _tombDays).inMilliseconds;
    tomb.removeWhere((_, t) => t < cutoff);
    puts['sync:tomb'] = tomb;
    bool dead(String key, int time) => tomb.containsKey(key) && tomb[key]! >= time;

    // 进度
    for (final e in ((remote['progress'] as Map?) ?? const {}).entries) {
      final r = e.value as List;
      final l = _box.get('progress:${e.key}') as List?;
      if (l == null || (r[2] as int) > (l[2] as int)) puts['progress:${e.key}'] = r;
    }

    // 历史：每本书取较新的
    final hist = <String, Map>{};
    for (final h in [..._maps(_box.get('history2')), ..._maps(remote['history'])]) {
      final old = hist[h['aid']];
      if (old == null || (h['time'] as int) > (old['time'] as int)) hist[h['aid'] as String] = h;
    }
    puts['history2'] = (hist.values.toList()..sort((a, b) => (b['time'] as int).compareTo(a['time'] as int))).take(300).toList();

    // 书签
    final marks = _maps(_box.get('bookmarks')).where((l) => !dead(bookmarkKey(l), l['time'] as int)).toList();
    for (final r in _maps(remote['bookmarks'])) {
      if (dead(bookmarkKey(r), r['time'] as int)) continue;
      final i = marks.indexWhere((l) => l['aid'] == r['aid'] && l['cid'] == r['cid'] && ((l['offset'] as int) - (r['offset'] as int)).abs() <= 40);
      if (i < 0) {
        marks.add(r);
      } else if ((r['time'] as int) > (marks[i]['time'] as int)) {
        marks[i] = r;
      }
    }
    puts['bookmarks'] = (marks..sort((a, b) => (b['time'] as int).compareTo(a['time'] as int)));

    // 已读章节、字数、评分
    for (final e in ((remote['read'] as Map?) ?? const {}).entries) {
      puts['read:${e.key}'] = {...((_box.get('read:${e.key}') as List?) ?? const []).cast<String>(), ...(e.value as List).cast<String>()}.toList();
    }
    for (final e in ((remote['readchars'] as Map?) ?? const {}).entries) {
      puts['readchars:${e.key}'] = max((_box.get('readchars:${e.key}') as int?) ?? 0, e.value as int);
    }
    for (final e in ((remote['rating'] as Map?) ?? const {}).entries) {
      if (((_box.get('rating:${e.key}') as int?) ?? 0) == 0 && (e.value as int) > 0) puts['rating:${e.key}'] = e.value;
    }
    for (final e in ((remote['vrate'] as Map?) ?? const {}).entries) {
      if (e.value is! Map) continue;
      final local = Map<String, int>.from(((_box.get('vrate:${e.key}') as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as int)));
      for (final vr in (e.value as Map).entries) {
        if ((local['${vr.key}'] ?? 0) == 0 && (vr.value as int) > 0) local['${vr.key}'] = vr.value as int;
      }
      if (local.isNotEmpty) puts['vrate:${e.key}'] = local;
    }

    // 规则：按编号并集，同一条取修改时间较新的；备注：并集，本机优先
    int ts(Map r) => (r['ts'] as int?) ?? 0;
    final rules = _maps(_box.get('rules')).where((r) => !dead('r:${r['id']}', ts(r))).toList();
    for (final r in _maps(remote['rules'])) {
      if (r['id'] == null || dead('r:${r['id']}', ts(r))) continue;
      final i = rules.indexWhere((l) => l['id'] == r['id']);
      if (i < 0) {
        rules.add(r);
      } else if (ts(r) > ts(rules[i])) {
        rules[i] = r;
      }
    }
    puts['rules'] = rules;
    for (final e in ((remote['notes'] as Map?) ?? const {}).entries) {
      final local = Map<String, String>.from(((_box.get('notes:${e.key}') as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')));
      for (final n in (e.value as Map).entries) {
        local.putIfAbsent('${n.key}', () => '${n.value}');
      }
      puts['notes:${e.key}'] = local;
    }

    // 书架分类（例如"在追"）与书架书籍（含重命名 name、所属分类 cats）
    final catIdMap = <String, String>{};
    final localCatMap = <String, String>{}; // 本机分类换了 id：旧 → 新
    if (remote['cats'] != null || remote['books'] != null) {
      final cats = _maps(_box.get('lib:cats')).where((c) => !dead('cat:${c['id']}', ts(c))).toList();
      for (final r in _maps(remote['cats'])) {
        final rId = '${r['id']}';
        final rName = '${r['name']}';
        final rTs = ts(r);
        if (dead('cat:$rId', rTs)) continue;
        final byId = cats.indexWhere((c) => c['id'] == rId);
        if (byId >= 0) {
          if (rTs > ts(cats[byId])) cats[byId] = {'id': rId, 'name': rName, 'ts': rTs};
        } else {
          final byName = cats.indexWhere((c) => c['name'] == rName);
          if (byName >= 0) {
            // 同名分类两边统一成同一个 id（取较小的），之后改名、删除才能跨设备对上
            final lId = '${cats[byName]['id']}';
            if (rId.compareTo(lId) < 0) {
              cats[byName] = {...cats[byName], 'id': rId};
              localCatMap[lId] = rId;
            } else {
              catIdMap[rId] = lId;
            }
          } else {
            cats.add({'id': rId, 'name': rName, 'ts': rTs});
          }
        }
      }
      puts['lib:cats'] = cats;

      final validCatIds = {for (final c in cats) '${c['id']}'};
      final localBooks = <String, Map<String, dynamic>>{};
      for (final e in ((_box.get('lib:books') as Map?) ?? const {}).entries) {
        final aid = '${e.key}';
        final b = Map<String, dynamic>.from(e.value as Map);
        b['cats'] = {for (final c in ((b['cats'] as List?) ?? const []).cast<String>()) localCatMap[c] ?? c}.toList();
        final bTime = max((b['added'] as int?) ?? 0, (b['ts'] as int?) ?? 0);
        if (!dead('lib:$aid', bTime)) localBooks[aid] = b;
      }
      for (final e in ((remote['books'] as Map?) ?? const {}).entries) {
        final aid = '${e.key}';
        if (e.value is! Map) continue;
        final r = Map<String, dynamic>.from(e.value as Map);
        final rAdded = (r['added'] as int?) ?? 0;
        final rTs = (r['ts'] as int?) ?? 0;
        if (dead('lib:$aid', max(rAdded, rTs))) continue;
        final rCats = {
          for (final c in ((r['cats'] as List?) ?? const []).cast<String>())
            if (validCatIds.contains(catIdMap[c] ?? c)) catIdMap[c] ?? c,
        }.toList();
        final l = localBooks[aid];
        if (l == null) {
          localBooks[aid] = {
            'aid': aid,
            'title': r['title'] ?? '',
            'img': r['img'] ?? '',
            'added': rAdded,
            'cats': rCats,
            'bid': null,
            'done': r['done'] == true,
            'name': r['name'],
            'ts': rTs,
          };
        } else {
          final lAdded = (l['added'] as int?) ?? 0;
          final lTs = (l['ts'] as int?) ?? 0;
          final lCats = [
            for (final c in ((l['cats'] as List?) ?? const []).cast<String>())
              if (validCatIds.contains(c)) c,
          ];
          final mergedName = rTs > lTs ? r['name'] : (lTs > rTs ? l['name'] : (l['name'] ?? r['name']));
          final mergedCats = rTs > lTs ? rCats : (lTs > rTs ? lCats : (lCats.isNotEmpty ? lCats : rCats));
          localBooks[aid] = {
            'aid': aid,
            'title': (l['title'] as String?)?.isNotEmpty == true ? l['title'] : (r['title'] ?? ''),
            'img': (l['img'] as String?)?.isNotEmpty == true ? l['img'] : (r['img'] ?? ''),
            'added': lAdded > 0 && rAdded > 0 ? min(lAdded, rAdded) : max(lAdded, rAdded),
            'cats': mergedCats,
            'bid': l['bid'],
            'done': (l['done'] == true) || (r['done'] == true),
            'name': mergedName,
            'ts': max(lTs, rTs),
          };
        }
      }
      puts['lib:books'] = localBooks;
      await _renameCatRefs(localCatMap, puts);
    }

    if (remote['shelfTabOrder'] is List && _box.get('shelfTabOrder') == null) {
      puts['shelfTabOrder'] = [for (final c in (remote['shelfTabOrder'] as List).cast<String>()) catIdMap[c] ?? c];
    }
    for (final e in ((remote['shelfOrder'] as Map?) ?? const {}).entries) {
      final key = '${e.key}'; // lib:<分类 id>
      final catKey = key.startsWith('lib:') ? 'lib:${catIdMap[key.substring(4)] ?? key.substring(4)}' : key;
      if (_box.get('shelfOrder:$catKey') == null && !puts.containsKey('shelfOrder:$catKey') && e.value is List) {
        puts['shelfOrder:$catKey'] = (e.value as List).cast<String>();
      }
    }

    // 分卷目录与卷封面（含手动挑过 / 裁剪过的 #crop= 封面，手动挑的优先于自动挑的）
    for (final e in ((remote['vols'] as Map?) ?? const {}).entries) {
      final l = _box.get('vols:${e.key}') as List?;
      final r = e.value as List?;
      if (r != null && (l == null || r.length > l.length)) puts['vols:${e.key}'] = r;
    }
    var coverChanged = false;
    final rVcover = (remote['vcover'] as Map?) ?? const {};
    final rVpick = (remote['vpick'] as Map?) ?? const {};
    for (final aid in {...rVcover.keys.map((k) => '$k'), ...rVpick.keys.map((k) => '$k')}) {
      final lPick = ((_box.get('vpick:$aid') as List?) ?? const []).cast<String>().toSet();
      final rPick = ((rVpick[aid] as List?) ?? const []).cast<String>().toSet();
      final lCover = Map<String, String>.from(((_box.get('vcover2:$aid') as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')));
      final rCover = Map<String, String>.from(((rVcover[aid] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')));
      final lTime = Map<String, int>.from(((_box.get('vpickTs:$aid') as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as int)));
      final rTime = Map<String, int>.from((((remote['vpickTs'] as Map?)?[aid] as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as int)));
      bool manual(Set<String> picks, String title, String? url) => picks.contains(title) || (url?.contains('#crop=') ?? false);
      // 有一台设备恢复了自动封面：比那次恢复早的手动封面作废，两边都去掉
      bool reset(Map<String, int> time, String title) => dead('vcover:$aid:$title', time[title] ?? 0);
      for (final title in lCover.keys.toList()) {
        if (manual(lPick, title, lCover[title]) && reset(lTime, title)) {
          lCover.remove(title);
          lPick.remove(title);
          lTime.remove(title);
          coverChanged = true;
        }
      }
      for (final e in rCover.entries) {
        final title = e.key, rUrl = e.value;
        final lUrl = lCover[title];
        if (manual(rPick, title, rUrl) && reset(rTime, title)) continue; // 已作废的手动封面
        final rManual = manual(rPick, title, rUrl);
        final lManual = manual(lPick, title, lUrl);
        final take = rManual
            ? !lManual || lUrl == null || lUrl.isEmpty || (rTime[title] ?? 0) > (lTime[title] ?? 0)
            : !lManual && (lUrl == null || lUrl.isEmpty) && rUrl.isNotEmpty;
        if (take && lUrl != rUrl) {
          lCover[title] = rUrl;
          coverChanged = true;
        }
        if (rManual && (rTime[title] ?? 0) > (lTime[title] ?? 0)) lTime[title] = rTime[title]!;
      }
      rPick.removeWhere((title) => reset(rTime, title));
      final mergedPick = {...lPick, ...rPick};
      puts['vcover2:$aid'] = lCover;
      puts['vpick:$aid'] = mergedPick.toList();
      if (lTime.isNotEmpty) puts['vpickTs:$aid'] = lTime;
    }

    // 更新列表与章节基准（让手机和电脑看到的更新一致）
    if (remote['updates'] is Map) {
      final ru = remote['updates'] as Map;
      final feedMap = <String, Map>{};
      for (final f in [..._maps(_box.get('updates')), ..._maps(ru['feed'])]) {
        final key = '${f['aid']}:${f['cid']}';
        final old = feedMap[key];
        if (old == null || (f['time'] as int) > (old['time'] as int)) feedMap[key] = f;
      }
      puts['updates'] = (feedMap.values.toList()..sort((a, b) => (b['time'] as int).compareTo(a['time'] as int))).take(300).toList();
      final known = Map<String, int>.from(((_box.get('updates:known') as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as int)));
      for (final e in ((ru['known'] as Map?) ?? const {}).entries) {
        known['${e.key}'] = max(known['${e.key}'] ?? 0, e.value as int);
      }
      puts['updates:known'] = known;
      final rSeen = (ru['seen'] as int?) ?? 0;
      final lSeen = (_box.get('updates:seen') as int?) ?? 0;
      if (rSeen > lSeen) puts['updates:seen'] = rSeen;
      for (final e in ((ru['at'] as Map?) ?? const {}).entries) {
        final k = 'updates:at:${e.key}';
        final rAt = e.value as int;
        final lAt = (_box.get(k) as int?) ?? 0;
        if (rAt > lAt) puts[k] = rAt;
      }
    }

    // 可选同步项：按本机的开关决定是否并入
    if (!kIsWeb && AppPrefs.read(P.syncAvatar, true) && remote['avatar'] is Map) {
      final ra = remote['avatar'] as Map;
      final rTs = (ra['ts'] as int?) ?? 0;
      final lTs = (_box.get('avatar:ts') as int?) ?? 0;
      if (rTs > lTs) {
        final data = ra['data'] as String?;
        if (data == null && ra['file'] != null) {
          // 导入的备份文件不带图片，保持原样
        } else if (data != null && data.isNotEmpty) {
          try {
            final bytes = base64Decode(data);
            final ext = p.extension('a${(ra['ext'] as String?) ?? '.png'}'); // 来自外部，只取扩展名
            Directory dir;
            try {
              dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'avatar'));
            } catch (_) {
              dir = Directory(p.join(Directory.systemTemp.path, 'ark_avatar'));
            }
            if (await dir.exists()) await dir.delete(recursive: true);
            await dir.create(recursive: true);
            final dest = File(p.join(dir.path, 'avatar_$rTs$ext'));
            await dest.writeAsBytes(bytes);
            puts['avatar'] = dest.path;
            puts['avatar:ts'] = rTs;
          } catch (_) {}
        } else {
          await _box.delete('avatar');
          puts['avatar:ts'] = rTs;
        }
      }
    }

    if (AppPrefs.read(P.syncShelfPrefs, false) && remote['shelfPrefs'] is Map) {
      final sp = remote['shelfPrefs'] as Map;
      final rTs = (sp['ts'] as int?) ?? 0;
      final lTs = (_box.get('sync:prefsTs') as int?) ?? 0;
      if (rTs > lTs) {
        if (sp['shelfOpts'] is Map) puts['shelfOpts'] = sp['shelfOpts'];
        for (final e in ((sp['p'] as Map?) ?? const {}).entries) {
          final k = '${e.key}';
          if (_isShelfPref(k)) puts[k] = e.value;
        }
        puts['sync:prefsTs'] = rTs;
      }
    }

    if (AppPrefs.read(P.syncReaderPrefs, false) && remote['readerPrefs'] is Map) {
      final rp = remote['readerPrefs'] as Map;
      final rTs = (rp['ts'] as int?) ?? 0;
      final lTs = (_box.get('sync:readerTs') as int?) ?? 0;
      if (rTs > lTs) {
        for (final e in ((rp['r'] as Map?) ?? const {}).entries) {
          puts['${e.key}'] = e.value;
        }
        if (rp['volumeDone'] != null) puts['p.${P.volumeDone}'] = rp['volumeDone'];
        puts['sync:readerTs'] = rTs;
      }
    }

    if (AppPrefs.read(P.syncAppearance, false) && remote['appearance'] is Map) {
      final ap = remote['appearance'] as Map;
      final rTs = (ap['ts'] as int?) ?? 0;
      final lTs = (_box.get('sync:appearanceTs') as int?) ?? 0;
      if (rTs > lTs) {
        if (ap['themeMode'] != null) puts['themeMode'] = ap['themeMode'];
        if (ap['palette'] != null) puts['palette'] = ap['palette'];
        for (final e in ((ap['p'] as Map?) ?? const {}).entries) {
          puts['${e.key}'] = e.value;
        }
        puts['sync:appearanceTs'] = rTs;
      }
    }

    // 统计：单独存放；删掉的书从对方的统计里去掉（删除之后又读过的留下，见 ReadingStats.stripBook），本机的也删一次
    final stats = Map<String, dynamic>.from(remote['stats'] as Map);
    final purged = Map<String, int>.from((_box.get('stats:purged') as Map?) ?? const {});
    final purge = <String, int>{};
    for (final e in tomb.entries.where((e) => e.key.startsWith('stats:'))) {
      final aid = e.key.substring(6);
      ReadingStats.stripBook(stats, aid, before: e.value);
      if (e.value > (purged[aid] ?? 0)) purge[aid] = e.value;
    }
    puts['sync:stats:${remote['device']}'] = jsonEncode(stats);
    await _box.putAll(puts);
    // 先删本机的再记「删过了」：中途被打断的话下次合并会再删一次（按日期删，重复删没有副作用）
    for (final MapEntry(key: aid, value: at) in purge.entries) {
      await ReadingStats.purgeLocal(aid, before: at);
      purged[aid] = at;
    }
    if (purge.isNotEmpty) await _box.put('stats:purged', purged);
    for (final aid in ((remote['read'] as Map?) ?? const {}).keys) {
      await Volumes.refreshDone('$aid');
    }
    if (coverChanged) Volumes.changes.value++;
    changes.value++;
  }

  /// 本机分类换了 id：书架顺序、标签顺序和存着分类 id 的设置跟着改。
  static Future<void> _renameCatRefs(Map<String, String> ids, Map<String, Object?> puts) async {
    if (ids.isEmpty) return;
    for (final MapEntry(key: from, value: to) in ids.entries) {
      final order = _box.get('shelfOrder:lib:$from');
      if (order != null) puts['shelfOrder:lib:$to'] = order;
      await _box.delete('shelfOrder:lib:$from');
    }
    List<String> mapped(Object? v) => [for (final c in ((v as List?) ?? const []).cast<String>()) ids[c] ?? c];
    if (_box.get('shelfTabOrder') != null) puts['shelfTabOrder'] = mapped(_box.get('shelfTabOrder'));
    for (final k in [P.hiddenTabs, P.updInclude, P.updExclude]) {
      if (_box.get('p.$k') != null) puts['p.$k'] = mapped(_box.get('p.$k'));
    }
    final def = _box.get('p.${P.defaultCat}');
    if (ids[def] != null) puts['p.${P.defaultCat}'] = ids[def];
  }

  /// 删掉一本书的统计：记下墓碑（本机已删过，下次合并不用再删），已经同步来的其他设备的统计也去掉。
  static Future<void> forgetBookStats(String aid) async {
    await tombstone(['stats:$aid']);
    final purged = Map<String, int>.from((_box.get('stats:purged') as Map?) ?? const {});
    purged[aid] = _tombs()['stats:$aid']!;
    await _box.put('stats:purged', purged);
    for (final k in _keys('sync:stats:').toList()) {
      final stats = Map<String, dynamic>.from(jsonDecode(_box.get(k) as String) as Map);
      ReadingStats.stripBook(stats, aid, before: purged[aid]);
      await _box.put(k, jsonEncode(stats));
    }
  }

  /// 其他设备的统计（设备 → 内容），统计页把它们加到本机数据上。
  /// 统计页一次构建要调用几百次：原文没变就复用解码结果（只读，调用方不要改）。
  static Iterable<Map<String, dynamic>> otherStats() => [
    for (final k in _keys('sync:stats:')) _decodeStats(k, _box.get(k) as String),
  ];

  static final _statsCache = <String, (String, Map<String, dynamic>)>{};

  static Map<String, dynamic> _decodeStats(String key, String raw) {
    final hit = _statsCache[key];
    if (hit != null && hit.$1 == raw) return hit.$2;
    final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    _statsCache[key] = (raw, m);
    return m;
  }

  /// 导入备份文件（别的设备或本机导出的快照）：规则同同步；返回 false 表示这是本机自己导出的。
  static Future<bool> importBackup(String json) async {
    final m = jsonDecode(json) as Map<String, dynamic>;
    if (m['device'] == deviceId) return false;
    await merge(m);
    return true;
  }

  // ---- WebDAV ----

  static Dio _dio(String pass) => Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 30), headers: {'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$pass'))}'}, validateStatus: (s) => s != null && s < 500));

  static String _dir() => '${url.endsWith('/') ? url : '$url/'}${Uri.encodeComponent(folder)}/';

  static String _decodeHref(String s) {
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }

  /// 目录里所有 `*.json` 的文件名（PROPFIND 的返回里取 href）。
  static List<String> parseListing(String xml) => [
    for (final m in RegExp(r'<(?:\w+:)?href>([^<]+)</(?:\w+:)?href>', caseSensitive: false).allMatches(xml))
      if (_decodeHref(m.group(1)!) case final href when href.endsWith('.json') && !href.endsWith('/')) href.split('/').last,
  ];

  static void _ok(Response r, String what) {
    if (r.statusCode == 401) throw '$what：用户名或应用密码不对（坚果云要用"第三方应用密码"，不是登录密码）';
    if (r.statusCode! >= 400) throw '$what失败（HTTP ${r.statusCode}）';
  }

  /// 测试连接：目录不存在就建出来。
  static Future<void> test() async {
    final dio = _dio(await password());
    try {
      final r = await dio.request(_dir(), options: Options(method: 'PROPFIND', headers: {'Depth': '0'}));
      if (r.statusCode == 404) {
        _ok(await dio.request(_dir(), options: Options(method: 'MKCOL')), '创建同步文件夹');
      } else {
        _ok(r, '连接');
      }
    } finally {
      dio.close();
    }
  }

  static bool _running = false;

  /// 完整同步一次：上传本机快照，读取并合并其他设备的快照。返回合并了几台设备。
  static Future<int> run() async {
    if (_running) throw '正在同步，请稍候';
    _running = true;
    final dio = _dio(await password());
    try {
      await test();
      await _pushAvatar(dio);
      final put = await dio.put('${_dir()}$deviceId.json', data: jsonEncode(snapshot()), options: Options(contentType: 'application/json; charset=utf-8'));
      _ok(put, '上传');
      final list = await dio.request(_dir(), options: Options(method: 'PROPFIND', headers: {'Depth': '1'}, responseType: ResponseType.plain));
      _ok(list, '读取目录');
      var merged = 0;
      for (final name in parseListing(list.data as String)) {
        if (name == '$deviceId.json') continue;
        final r = await dio.get('${_dir()}${Uri.encodeComponent(name)}', options: Options(responseType: ResponseType.plain));
        _ok(r, '下载 $name');
        final remote = jsonDecode(r.data as String) as Map<String, dynamic>;
        await _pullAvatar(dio, remote);
        await merge(remote);
        merged++;
      }
      await _box.put('sync:last', DateTime.now().millisecondsSinceEpoch);
      return merged;
    } finally {
      dio.close();
      _running = false;
    }
  }

  /// 自动同步用：没配置、正在同步、距上次不到 [minGap] 就跳过；出错不打扰用户。
  static Future<void> auto({Duration minGap = const Duration(minutes: 3)}) async {
    if (!configured || _running || DateTime.now().millisecondsSinceEpoch - lastSync < minGap.inMilliseconds) return;
    try {
      await run();
    } catch (_) {}
  }
}

/// 同步页用：手动同步的状态，同步完成后让用到统计的界面重新读取。
class SyncStatus {
  const SyncStatus({this.busy = false, this.message});

  final bool busy;
  final String? message;
}

class SyncController extends Notifier<SyncStatus> {
  @override
  SyncStatus build() => const SyncStatus();

  void refreshProviders() {
    ref.invalidate(libraryProvider);
    ref.invalidate(updateProvider);
    ref.invalidate(avatarProvider);
    ref.invalidate(appPrefsProvider);
    ref.invalidate(readerPrefsProvider);
    ref.invalidate(themeModeProvider);
    ref.invalidate(paletteProvider);
  }

  Future<void> run() async {
    if (state.busy) return;
    state = const SyncStatus(busy: true);
    try {
      final n = await Sync.run();
      state = SyncStatus(message: n == 0 ? '已同步（还没有别的设备的数据）' : '已同步，合并了 $n 台设备的数据');
    } catch (e) {
      state = SyncStatus(message: e is DioException ? '网络错误：${e.message ?? e.type.name}' : '$e');
    }
  }
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);
