import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/bookmarks.dart';
import 'package:ark_novel/next/rules.dart';
import 'package:ark_novel/next/stats.dart';
import 'package:ark_novel/next/sync.dart';

void main() {
  late Box box;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_sync_test').path);
    box = await Hive.openBox('session');
  });

  setUp(() => box.clear());

  Map<String, dynamic> remote({Map<String, dynamic> extra = const {}}) => {
    'v': 1,
    'device': 'other',
    'progress': {},
    'history': [],
    'bookmarks': [],
    'read': {},
    'readchars': {},
    'rating': {},
    'rules': [],
    'notes': {},
    'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}},
    ...extra,
  };

  test('进度：新的赢；书签、已读章节、备注取并集，本机的备注优先', () async {
    await box.put('progress:1', ['a', 10, 1000]);
    await box.put('progress:2', ['x', 5, 9000]);
    await box.put('read:1', ['a']);
    await box.put('notes:1', {'r1': '本机备注'});
    await Sync.merge(remote(extra: {
      'progress': {'1': ['b', 99, 2000], '2': ['y', 1, 100]},
      'read': {'1': ['b']},
      'bookmarks': [
        {'aid': '1', 'book': 'B', 'cid': 'b', 'chapter': 'c', 'offset': 5, 'excerpt': 'e', 'time': 1},
      ],
      'notes': {'1': {'r1': '对方备注', 'r2': '新备注'}},
    }));
    expect(box.get('progress:1'), ['b', 99, 2000]);
    expect(box.get('progress:2'), ['x', 5, 9000]);
    expect((box.get('read:1') as List).toSet(), {'a', 'b'});
    expect((box.get('bookmarks') as List).length, 1);
    expect(box.get('notes:1'), {'r1': '本机备注', 'r2': '新备注'});
  });

  test('重复合并同一份数据结果不变', () async {
    final r = remote(extra: {
      'history': [
        {'aid': '1', 'title': 'T', 'img': '', 'cid': 'a', 'chapter': 'c', 'time': 5},
      ],
      'rules': [
        {'p': 'x', 'r': '', 'e': true, 'k': 1, 'c': 1, 'n': '', 'a': '', 'id': 'h1'},
      ],
    });
    await Sync.merge(r);
    await Sync.merge(r);
    expect((box.get('history2') as List).length, 1);
    expect((box.get('rules') as List).length, 1);
  });

  test('其他设备的统计单独存放，显示时相加，本机继续累加不会带上对方的数', () async {
    await box.put('stats:day', {'2026-10-20': 60});
    await Sync.merge(remote(extra: {
      'stats': {'day': {'2026-10-20': 100}, 'book': {'1': 100}, 'chapters': 3, 'meta': {}, 'days': {'1': ['2026-10-20']}},
    }));
    expect(ReadingStats.perDay()['2026-10-20'], 160);
    expect(ReadingStats.chapters, 3);
    await ReadingStats.addSeconds('1', 30);
    expect(box.get('stats:day'), {ReadingStats.dayKey(DateTime.now()): 30, '2026-10-20': 60}.map((k, v) => MapEntry(k, v)));
    expect(Sync.snapshot()['stats']['day'], isNot(contains('160')));
  });

  test('删除靠墓碑同步：对方删了本机也删，本机删了不会被对方带回来，删除后重新添加的保留', () async {
    Map<String, Object> mark(int offset, int time) => {'aid': '1', 'book': 'B', 'cid': 'c', 'chapter': 'c', 'offset': offset, 'excerpt': 'e', 'time': time};
    Map<String, Object> rule(String id, int ts, {String p = 'x'}) => {'p': p, 'r': '', 'e': true, 'k': 1, 'c': 1, 'n': '', 'a': '', 'id': id, 'ts': ts};
    final now = DateTime.now().millisecondsSinceEpoch;

    // 对方删了：本机的旧书签、旧规则被删
    await box.put('bookmarks', [mark(100, 10), mark(500, now + 10000)]);
    await box.put('rules', [rule('a', 5), rule('b', 5)]);
    await Sync.merge(remote(extra: {
      'tomb': {'b:1:c:100': now, 'b:1:c:500': now, 'r:a': now},
    }));
    expect((box.get('bookmarks') as List).map((e) => e['offset']), [500]); // 删除之后又加的书签留下
    expect((box.get('rules') as List).map((e) => e['id']), ['b']);

    // 本机删了：对方的旧数据带不回来
    await Bookmarks.remove(Bookmarks.all().single);
    await ReplaceRules.save([]);
    await Sync.merge(remote(extra: {
      'bookmarks': [mark(500, 20)],
      'rules': [rule('b', 5)],
    }));
    expect(box.get('bookmarks'), isEmpty);
    expect(box.get('rules'), isEmpty);
  });

  test('规则改动按修改时间：对方改得新就用对方的', () async {
    await ReplaceRules.save([const ReplaceRule(pattern: 'old', replacement: '', id: 'r1', kind: RuleKind.highlight)]);
    final at = (box.get('rules') as List).single['ts'] as int;
    expect(at, greaterThan(0));
    await Sync.merge(remote(extra: {
      'rules': [
        {'p': 'new', 'r': '', 'e': true, 'k': 1, 'c': 1, 'n': '', 'a': '', 'id': 'r1', 'ts': at + 5},
      ],
    }));
    expect((box.get('rules') as List).single['p'], 'new');
    // 没改动的规则再保存一次，修改时间不变
    await ReplaceRules.save(ReplaceRules.all());
    expect((box.get('rules') as List).single['ts'], at + 5);
  });

  test('解析 PROPFIND 返回的文件名', () {
    const xml = '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/hikari/</d:href></d:response><d:response><d:href>/dav/hikari/d1%20a.json</d:href></d:response></d:multistatus>';
    expect(Sync.parseListing(xml), ['d1 a.json']);
  });

  test('WebDAV 全流程：自动建文件夹、上传本机快照、读取并合并别的设备', () async {
    final files = <String, String>{};
    var folderMade = false;
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final path = Uri.decodeFull(req.uri.path);
      final body = await utf8.decoder.bind(req).join();
      final res = req.response;
      if (req.headers.value('authorization') != 'Basic ${base64Encode(utf8.encode('me:secret'))}') {
        res.statusCode = 401;
      } else if (req.method == 'PROPFIND' && path == '/dav/hikari/') {
        if (!folderMade) {
          res.statusCode = 404;
        } else {
          res.statusCode = 207;
          res.write('<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/hikari/</d:href></d:response>${[for (final k in files.keys) '<d:response><d:href>/dav/hikari/$k</d:href></d:response>'].join()}</d:multistatus>');
        }
      } else if (req.method == 'MKCOL') {
        folderMade = true;
        res.statusCode = 201;
      } else if (req.method == 'PUT') {
        files[path.split('/').last] = body;
        res.statusCode = 201;
      } else if (req.method == 'GET' && files.containsKey(path.split('/').last)) {
        res.write(files[path.split('/').last]);
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    folderMade = false;
    files['other.json'] = jsonEncode(remote(extra: {
      'progress': {'7': ['c', 3, 5000]},
    }));
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'secret', folder: 'hikari');
    await box.put('progress:1', ['a', 1, 100]);

    expect(await Sync.run(), 1);
    expect(box.get('progress:7'), ['c', 3, 5000]);
    expect(files.keys.where((k) => k != 'other.json').length, 1);
    expect(jsonDecode(files['${Sync.deviceId}.json']!)['progress']['1'], ['a', 1, 100]);

    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'wrong', folder: 'hikari');
    await expectLater(Sync.run(), throwsA(contains('应用密码')));
    await server.close(force: true);
  });
}
