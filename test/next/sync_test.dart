import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/app_prefs.dart';
import 'package:ark_novel/next/bookmarks.dart';
import 'package:ark_novel/next/rules.dart';
import 'package:ark_novel/next/stats.dart';
import 'package:ark_novel/next/sync.dart';
import 'package:ark_novel/next/volumes.dart';

void main() {
  late Box box;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_sync_test').path);
    box = await Hive.openBox('session');
  });

  setUp(() => box.clear());

  statsDeleteTests(() => box);

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

  test('其他设备的统计更新后不会读到旧的解码结果', () async {
    Map<String, dynamic> stats(int n) => {'stats': {'day': {}, 'book': {}, 'chapters': n, 'meta': {}, 'days': {}}};
    await Sync.merge(remote(extra: stats(1)));
    expect(ReadingStats.chapters, 1);
    await Sync.merge(remote(extra: stats(2)));
    expect(ReadingStats.chapters, 2);
  });

  test('解析 PROPFIND 返回的文件名', () {
    const xml = '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/ArkNovel/</d:href></d:response><d:response><d:href>/dav/ArkNovel/sub.json/</d:href></d:response><d:response><d:href>/dav/ArkNovel/d1%20a.json</d:href></d:response><d:response><d:href>/dav/ArkNovel/bad%ZZ.json</d:href></d:response></d:multistatus>';
    expect(Sync.parseListing(xml), ['d1 a.json', 'bad%ZZ.json']);
  });

  test('分卷评分、按章统计与读完状态跟随同步更新', () async {
    await box.put('vols:1', [
      {'t': '第一卷', 'c': ['c1', 'c2'], 'i': null},
    ]);
    await box.put('read:1', ['c1']);
    await box.put('vrate:1', {'第一卷': 3});
    await box.put('stats:ch:1', {
      'c1': {'2026-10-20': 40},
    });
    await Sync.merge(remote(extra: {
      'read': {'1': ['c2']},
      'vrate': {
        '1': {'第一卷': 5, '第二卷': 4},
      },
      'stats': {
        'day': {},
        'book': {},
        'chapters': 0,
        'meta': {},
        'days': {},
        'ch': {
          '1': {
            'c1': {'2026-10-20': 25},
            'c2': {'2026-10-21': 50},
          },
        },
      },
    }));
    expect(Volumes.done('1').containsKey('第一卷'), isTrue);
    expect(Volumes.rating('1', '第一卷'), 3); // 本机已评的不被覆盖
    expect(Volumes.rating('1', '第二卷'), 4);
    expect(ReadingStats.chapterSeconds('1')['c1']?['2026-10-20'], 65);
    expect(ReadingStats.chapterSeconds('1')['c2']?['2026-10-21'], 50);
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
      } else if (req.method == 'PROPFIND' && path == '/dav/ArkNovel/') {
        if (!folderMade) {
          res.statusCode = 404;
        } else {
          res.statusCode = 207;
          res.write('<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/ArkNovel/</d:href></d:response>${[for (final k in files.keys) '<d:response><d:href>/dav/ArkNovel/$k</d:href></d:response>'].join()}</d:multistatus>');
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
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'secret', folder: 'ArkNovel');
    await box.put('progress:1', ['a', 1, 100]);

    expect(await Sync.run(), 1);
    expect(box.get('progress:7'), ['c', 3, 5000]);
    expect(files.keys.where((k) => k != 'other.json').length, 1);
    expect(jsonDecode(files['${Sync.deviceId}.json']!)['progress']['1'], ['a', 1, 100]);

    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'wrong', folder: 'ArkNovel');
    await expectLater(Sync.run(), throwsA(contains('应用密码')));
    await server.close(force: true);
  });

  test('书架分类（含同名分类合并）、书籍改名、裁剪封面、更新列表与可选设置同步', () async {
    await box.put('lib:cats', [
      {'id': 'c_local', 'name': '在追', 'ts': 100},
    ]);
    await box.put('lib:books', {
      '1': {'aid': '1', 'title': '原名', 'img': 'i1', 'added': 100, 'cats': <String>[], 'bid': 'b1', 'done': false, 'name': null, 'ts': 100},
    });
    await box.put('vcover2:1', {'第一卷': 'https://example.com/auto.jpg'});

    await Sync.merge(remote(extra: {
      'cats': [
        {'id': 'c_remote', 'name': '在追', 'ts': 200},
        {'id': 'c_new', 'name': '養肥', 'ts': 200},
      ],
      'books': {
        '1': {'aid': '1', 'title': '原名', 'img': 'i1', 'added': 100, 'cats': ['c_remote'], 'bid': 'b2', 'done': true, 'name': '自定义译名', 'ts': 300},
      },
      'vcover': {
        '1': {'第一卷': 'https://example.com/manual.jpg#crop=0.5,0,0.5,1'},
      },
      'vpick': {
        '1': ['第一卷'],
      },
      'updates': {
        'feed': [
          {'aid': '1', 'title': '原名', 'img': 'i1', 'chapter': '新章节', 'cid': 'c9', 'time': 500},
        ],
        'known': {'1': 15},
        'seen': 400,
        'at': {'1': 500},
      },
      'appearance': {
        'ts': 999,
        'themeMode': 2,
        'palette': 3,
      },
    }));

    final cats = (box.get('lib:cats') as List).cast<Map>();
    expect(cats.map((c) => c['name']), ['在追', '養肥']); // 同名"在追"不重复建
    final b1 = (box.get('lib:books') as Map)['1'] as Map;
    expect(b1['name'], '自定义译名');
    expect(b1['cats'], ['c_local']); // 远端 c_remote 自动映射到本机同名的 c_local
    expect(b1['bid'], 'b1'); // 本机 bid 保留
    expect(Volumes.cover('1', '第一卷'), 'https://example.com/manual.jpg#crop=0.5,0,0.5,1'); // 手动裁剪封面覆盖自动封面
    expect((box.get('updates') as List).length, 1);
    expect((box.get('updates:known') as Map)['1'], 15);
    expect(box.get('themeMode'), isNull); // 默认不同步外观与主题
  });

  test('同名分类统一 id 后，删除和改名能跨设备对上', () async {
    await box.put('lib:cats', [
      {'id': 'c_z', 'name': '在追', 'ts': 100},
    ]);
    await box.put('lib:books', {
      '1': {'aid': '1', 'title': 't', 'img': '', 'added': 1, 'cats': ['c_z'], 'bid': null, 'done': false, 'name': null, 'ts': 1},
    });
    await box.put('shelfOrder:lib:c_z', ['1']);
    await box.put('shelfTabOrder', ['c_z']);
    await box.put('p.${P.hiddenTabs}', ['c_z']);
    final other = {'cats': [{'id': 'c_a', 'name': '在追', 'ts': 100}], 'books': {}};
    await Sync.merge(remote(extra: other));
    expect((box.get('lib:cats') as List).map((c) => c['id']), ['c_a']);
    expect((box.get('lib:books') as Map)['1']['cats'], ['c_a']);
    expect(box.get('shelfOrder:lib:c_a'), ['1']);
    expect(box.get('shelfOrder:lib:c_z'), isNull);
    expect(box.get('shelfTabOrder'), ['c_a']);
    expect(box.get('p.${P.hiddenTabs}'), ['c_a']);

    // 另一台改名：id 相同，按时间取新的，不会变成两个
    await Sync.merge(remote(extra: {'cats': [{'id': 'c_a', 'name': '追番', 'ts': 200}], 'books': {}}));
    expect((box.get('lib:cats') as List).map((c) => c['name']), ['追番']);

    // 另一台删除：不复活
    await Sync.merge(remote(extra: {'cats': [], 'books': {}, 'tomb': {'cat:c_a': DateTime.now().millisecondsSinceEpoch}}));
    expect(box.get('lib:cats'), isEmpty);
    await Sync.merge(remote(extra: other));
    expect(box.get('lib:cats'), isEmpty);
  });

  test('可选设置：只有这组改过才更新时间，时间相同不互相覆盖', () async {
    await AppPrefs.write(P.lock, true);
    await AppPrefs.write(P.lastTab, 'x');
    await AppPrefs.write(P.colsPortrait, 3);
    await AppPrefs.write(P.syncShelfPrefs, true);
    expect(box.get('sync:prefsTs'), isNull);
    await box.put('p.${P.resumeBar}', true);
    await Sync.merge(remote(extra: {'shelfPrefs': {'ts': 0, 'p': {'p.${P.resumeBar}': false}}}));
    expect(box.get('p.${P.resumeBar}'), isTrue);

    await Sync.merge(remote(extra: {'shelfPrefs': {'ts': 5, 'p': {'p.${P.resumeBar}': false, 'p.${P.lastTab}': 'y'}}}));
    expect(box.get('p.${P.resumeBar}'), isFalse);
    expect(box.get('p.${P.lastTab}'), 'x');
    await AppPrefs.write(P.resumeBar, true);
    expect(box.get('sync:prefsTs') as int, greaterThan(5));
  });

  test('恢复自动封面能跨设备生效，之后重新挑的不受影响', () async {
    await box.put('vcover2:1', {'一': 'mine'});
    await box.put('vpick:1', ['一']);
    await box.put('vpickTs:1', {'一': 100});
    final picked = {'vcover': {'1': {'一': 'theirs'}}, 'vpick': {'1': ['一']}, 'vpickTs': {'1': {'一': 50}}};

    // 手动对手动：时间新的赢
    await Sync.merge(remote(extra: picked));
    expect(Volumes.cover('1', '一'), 'mine');

    // 另一台恢复了自动封面：本机的手动封面也去掉
    final at = DateTime.now().millisecondsSinceEpoch;
    await Sync.merge(remote(extra: {'vcover': {'1': <String, String>{}}, 'vpick': {'1': <String>[]}, 'tomb': {'vcover:1:一': at}}));
    expect(Volumes.cover('1', '一'), isNull);

    // 还没收到恢复的设备传来旧封面：不写回
    await Sync.merge(remote(extra: picked));
    expect(Volumes.cover('1', '一'), isNull);

    // 恢复之后又挑了新的：生效
    await Sync.merge(remote(extra: {'vcover': {'1': {'一': 'new'}}, 'vpick': {'1': ['一']}, 'vpickTs': {'1': {'一': at + 1000}}}));
    expect(Volumes.cover('1', '一'), 'new');
  });

  test('头像单独传文件：快照不带图片，没变不重传，对方新的才下载', () async {
    final files = <String, String>{};
    final puts = <String>[];
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final name = Uri.decodeFull(req.uri.path).split('/').last;
      final body = await utf8.decoder.bind(req).join();
      final res = req.response;
      if (req.method == 'PROPFIND') {
        res.statusCode = 207;
        res.write('<d:multistatus xmlns:d="DAV:">${[for (final k in files.keys) '<d:response><d:href>/dav/A/$k</d:href></d:response>'].join()}</d:multistatus>');
      } else if (req.method == 'PUT') {
        files[name] = body;
        puts.add(name);
        res.statusCode = 201;
      } else if (files.containsKey(name)) {
        res.write(files[name]);
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    final tmp = Directory.systemTemp.createTempSync('ark_avatar_test');
    await box.put('avatar', (File('${tmp.path}/a.png')..writeAsStringSync('mine')).path);
    await box.put('avatar:ts', 5);
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'x', folder: 'A');

    await Sync.run();
    final mine = '${Sync.deviceId}.avatar';
    expect(files[mine], 'mine');
    final snap = jsonDecode(files['${Sync.deviceId}.json']!) as Map;
    expect((snap['avatar'] as Map)['file'], mine);
    expect((snap['avatar'] as Map).containsKey('data'), isFalse);

    puts.clear();
    files['o.avatar'] = 'theirs';
    files['o.json'] = jsonEncode(remote(extra: {'avatar': {'ts': 9, 'ext': '/../../evil.png', 'file': 'o.avatar'}}));
    await Sync.run();
    expect(puts, isNot(contains(mine)));
    expect(box.get('avatar:ts'), 9);
    expect(File(box.get('avatar') as String).readAsStringSync(), 'theirs');
    expect(box.get('avatar') as String, endsWith('.png'));
    expect(box.get('avatar') as String, isNot(contains('evil')));
    await server.close(force: true);
  });
}

void statsDeleteTests(Box Function() box) {
  test('删一本书的统计：本机、已同步的都去掉，其他书不动；再合并不会回来，删之后又读的留下', () async {
    final b = box();
    await b.put('stats:day', {'2026-01-01': 100, '2026-01-02': 50});
    await b.put('stats:book', {'1': 90, '2': 60});
    await b.put('stats:days:1', ['2026-01-01']);
    await b.put('stats:ch:1', {'c': {'2026-01-01': 90}});
    await b.put('stats:meta', {'1': {'t': 'a'}, '2': {'t': 'b'}});
    final other = {'day': {'2026-01-01': 30}, 'book': {'1': 30}, 'chapters': 1, 'meta': {'1': {'t': 'a'}}, 'days': {'1': ['2026-01-01']}, 'ch': {'1': {'c': {'2026-01-01': 30}}}};
    await b.put('sync:stats:other', jsonEncode(other));

    await ReadingStats.deleteBook('1');
    expect(ReadingStats.perBook(), {'2': 60});
    expect(ReadingStats.perDay(), {'2026-01-01': 10, '2026-01-02': 50});
    expect(ReadingStats.bookDays('1'), isEmpty);
    expect(ReadingStats.chapterSeconds('1'), isEmpty);

    Map<String, dynamic> snapshot(Map stats) => {'v': 1, 'device': 'other', 'progress': {}, 'history': [], 'bookmarks': [], 'read': {}, 'readchars': {}, 'rating': {}, 'rules': [], 'notes': {}, 'stats': stats};
    await Sync.merge(snapshot(other));
    expect(ReadingStats.perBook(), {'2': 60});

    final later = ReadingStats.dayKey(DateTime.now().add(const Duration(days: 1)));
    await Sync.merge(snapshot({'day': {later: 5}, 'book': {'1': 5}, 'chapters': 1, 'meta': {}, 'days': {'1': [later]}, 'ch': {}}));
    expect(ReadingStats.perBook()['1'], 5);
  });

  test('别的设备删的书：本机只删删除那天及之前的，之后几天读的留下', () async {
    final b = box();
    await b.put('stats:day', {'2026-01-01': 40, '2026-01-03': 70});
    await b.put('stats:book', {'1': 90, '2': 20});
    await b.put('stats:days:1', ['2026-01-01', '2026-01-03']);
    await b.put('stats:ch:1', {'c': {'2026-01-01': 30, '2026-01-03': 60}});
    final tomb = DateTime(2026, 1, 2, 12).millisecondsSinceEpoch;
    final snap = {'v': 1, 'device': 'other', 'progress': {}, 'history': [], 'bookmarks': [], 'read': {}, 'readchars': {}, 'rating': {}, 'rules': [], 'notes': {}, 'tomb': {'stats:1': tomb}, 'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}, 'ch': {}}};
    await Sync.merge(snap);
    expect(ReadingStats.bookDays('1'), ['2026-01-03']);
    expect(ReadingStats.chapterSeconds('1'), {'c': {'2026-01-03': 60}});
    expect(ReadingStats.perBook(), {'1': 60, '2': 20});
    expect(ReadingStats.perDay(), {'2026-01-01': 10, '2026-01-03': 70});
    expect((b.get('stats:purged') as Map)['1'], tomb);
  });

  test('删除那天：最后一次读在删除之后就整天留下，否则去掉', () {
    final tomb = DateTime(2026, 1, 2, 12).millisecondsSinceEpoch;
    Map<String, dynamic> stats(int last) => {
      'day': {'2026-01-02': 50},
      'book': {'1': 50},
      'meta': {'1': {'t': 'a'}},
      'days': {'1': ['2026-01-02']},
      'ch': {'1': {'c': {'2026-01-02': 50}}},
      'last': {'1': last},
    };
    final after = stats(tomb + 1000);
    ReadingStats.stripBook(after, '1', before: tomb);
    expect(after['book'], {'1': 50});
    expect(after['days'], {'1': ['2026-01-02']});

    final before = stats(tomb - 1000);
    ReadingStats.stripBook(before, '1', before: tomb);
    expect(before['book'], isEmpty);
    expect(before['day'], isEmpty);
    expect(before['meta'], isEmpty);
    expect(before['ch'], isEmpty);
  });

  test('别的设备删的书：本机只删一次，之后又读的不再被删', () async {
    final b = box();
    await b.put('stats:book', {'1': 90});
    await b.put('stats:days:1', ['2026-01-01']);
    final tomb = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> snapshot() => {'v': 1, 'device': 'other', 'progress': {}, 'history': [], 'bookmarks': [], 'read': {}, 'readchars': {}, 'rating': {}, 'rules': [], 'notes': {}, 'tomb': {'stats:1': tomb}, 'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}, 'ch': {}}};
    await Sync.merge(snapshot());
    expect(ReadingStats.perBook(), isEmpty);
    await ReadingStats.addSeconds('1', 10);
    await Sync.merge(snapshot());
    expect(ReadingStats.perBook()['1'], 10);
  });
}
