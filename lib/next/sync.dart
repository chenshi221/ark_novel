import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

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

  static const _secure = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false)); // 没开发者签名的 Mac 版用不了新式钥匙串（-34018）

  static String get url => (_box.get('sync:url') as String?) ?? 'https://dav.jianguoyun.com/dav/';
  static String get user => (_box.get('sync:user') as String?) ?? '';
  static const defaultFolder = 'ArkNovel';
  static String get folder => (_box.get('sync:folder') as String?) ?? defaultFolder;
  static int get lastSync => (_box.get('sync:last') as int?) ?? 0;
  static bool get configured => user.isNotEmpty;

  /// 应用密码：优先放系统安全存储，不可用时（比如没签名的 Mac 版）退回本地数据库。
  static Future<String> password() async {
    try {
      final p = await _secure.read(key: 'syncPass');
      if (p != null) return p;
    } catch (_) {}
    return (_box.get('sync:pass') as String?) ?? '';
  }

  static Future<void> save({required String url, required String user, required String pass, required String folder}) async {
    await _box.putAll({'sync:url': url.trim(), 'sync:user': user.trim(), 'sync:folder': folder.trim().isEmpty ? defaultFolder : folder.trim()});
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

  /// 本机要同步的数据（不含从别的设备并入的统计）。
  static Map<String, dynamic> snapshot() {
    Map<String, dynamic> byAid(String prefix) => {for (final k in _keys(prefix)) k.substring(prefix.length): _box.get(k)};
    return {
      'v': 2,
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
      'stats': {
        'day': _box.get('stats:day') ?? const {},
        'book': _box.get('stats:book') ?? const {},
        'chapters': _box.get('stats:chapters') ?? 0,
        'meta': _box.get('stats:meta') ?? const {},
        'days': byAid('stats:days:'),
        'ch': byAid('stats:ch:'),
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

    // 统计：单独存放
    puts['sync:stats:${remote['device']}'] = jsonEncode(remote['stats']);
    await _box.putAll(puts);
    for (final aid in ((remote['read'] as Map?) ?? const {}).keys) {
      await Volumes.refreshDone('$aid');
    }
  }

  /// 其他设备的统计（设备 → 内容），统计页把它们加到本机数据上。
  static Iterable<Map<String, dynamic>> otherStats() => [
    for (final k in _keys('sync:stats:')) Map<String, dynamic>.from(jsonDecode(_box.get(k) as String) as Map),
  ];

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
      final put = await dio.put('${_dir()}$deviceId.json', data: jsonEncode(snapshot()), options: Options(contentType: 'application/json; charset=utf-8'));
      _ok(put, '上传');
      final list = await dio.request(_dir(), options: Options(method: 'PROPFIND', headers: {'Depth': '1'}, responseType: ResponseType.plain));
      _ok(list, '读取目录');
      var merged = 0;
      for (final name in parseListing(list.data as String)) {
        if (name == '$deviceId.json') continue;
        final r = await dio.get('${_dir()}${Uri.encodeComponent(name)}', options: Options(responseType: ResponseType.plain));
        _ok(r, '下载 $name');
        await merge(jsonDecode(r.data as String) as Map<String, dynamic>);
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
