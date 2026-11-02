import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/backup.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String support;
  late String zip;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ark_backup_test');
    Hive.init(tmp.path);
    support = p.join(tmp.path, 'support');
    zip = p.join(tmp.path, 'b.zip');
    await Directory(p.join(support, 'imgcache')).create(recursive: true);
  });

  tearDown(() async {
    await Hive.close();
    tmp.deleteSync(recursive: true);
  });

  test('导出、改乱、导入后除登录信息外完全恢复，多出来的数据被清掉', () async {
    final box = await Hive.openBox('session');
    final data = {
      'lib:books': {'1': {'aid': '1', 'added': 5, 'cats': ['c']}},
      'lib:cats': [{'id': 'c', 'name': '在追'}],
      'stats:day': {'2026-10-21': 2728},
      'stats:ch:1': {'a': {'2026-10-21': 7}},
      'vols:1': [{'t': '第一卷'}],
      'vdone:1': {'第一卷': 9},
      'vrate:1': {'第一卷': 5},
      'updates': [{'aid': '1', 'time': 3}],
      'updates:at:1': 3,
      'sync:device': 'dA',
      'sync:stats:dB': '{}',
      'r.fontSize': 18.0,
      'p.shelf.perCat': true,
      'palette': 7,
      'searchHistory': ['冰菓'],
    };
    await box.putAll(data);
    await box.putAll({'cookie': 'old-cookie', 'cf:a.com': 'old-cf', 'sync:user': 'old-user', 'avatar': '/data/old/files/avatar/x.png'});
    await File(p.join(support, 'imgcache', 'cover')).writeAsString('封面');
    await Directory(p.join(support, 'avatar')).create();
    await File(p.join(support, 'avatar', 'x.png')).writeAsString('头像');

    await Backup.pack(zip, Backup.make(), support);

    // 备份里没有登录信息
    final input = InputFileStream(zip);
    final files = ZipDecoder().decodeStream(input).files;
    expect(files.map((f) => f.name).toSet(), {'data.json', 'files/avatar/x.png'}); // 封面能重新下载，不进备份
    final json = utf8.decode(files.firstWhere((f) => f.name == 'data.json').content as List<int>);
    await input.close();
    expect(json, isNot(contains('old-cookie')));
    expect(json, isNot(contains('old-cf')));
    expect(json, isNot(contains('old-user')));

    // 恢复之前本机变了：多了书和新键，换了登录，头像没了
    await box.put('lib:books', {'2': {'aid': '2'}});
    await box.put('stats:ch:9', {});
    await box.put('cookie', 'new-cookie');
    await File(p.join(support, 'avatar', 'x.png')).delete();
    await box.close();

    await Backup.unpack(zip, support);
    await Backup.apply(support);

    final restored = await Hive.openBox('session');
    for (final e in data.entries) {
      expect(restored.get(e.key), e.value, reason: e.key);
    }
    expect(restored.containsKey('stats:ch:9'), false);
    expect(restored.get('cookie'), 'new-cookie');
    expect(restored.get('avatar'), p.join(support, 'avatar', 'x.png'));
    expect(File(p.join(support, 'avatar', 'x.png')).readAsStringSync(), '头像');
    expect(File(p.join(support, 'imgcache', 'cover')).existsSync(), true); // 缓存不动
    expect(Directory(p.join(support, 'restore_pending')).existsSync(), false);

    // 没有待恢复的备份时什么也不做
    await restored.close();
    await Backup.apply(support);
    expect((await Hive.openBox('session')).get('palette'), 7);
  });

  Future<void> writeZip(Map<String, String> files) async {
    final z = ZipFileEncoder()..create(zip);
    files.forEach((k, v) => z.addArchiveFile(ArchiveFile.string(k, v)));
    await z.close();
  }

  test('不认识的文件不解压、不生效', () async {
    for (final files in [
      {'../evil': 'x', 'data.json': '{"backup":3,"box":{}}'},
      {'files/avatar/../../evil': 'x', 'data.json': '{"backup":3,"box":{}}'},
      {'files/imgcache/a': 'x', 'data.json': '{"backup":3,"box":{}}'},
      {'files/avatar/a': 'x'},
      {'data.json': '{"backup":2}'},
    ]) {
      await writeZip(files);
      await expectLater(Backup.unpack(zip, support), throwsA(isA<FormatException>()), reason: '$files');
      expect(Directory(p.join(support, 'restore_pending')).existsSync(), false);
    }
  });

  test('备份里的登录信息即使被手动加进去也不会写入', () async {
    final box = await Hive.openBox('session');
    await box.put('cookie', 'mine');
    await box.close();
    await writeZip({'data.json': '{"backup":3,"box":{"cookie":"evil","palette":3}}'});
    await Backup.unpack(zip, support);
    await Backup.apply(support);
    final b = await Hive.openBox('session');
    expect(b.get('cookie'), 'mine');
    expect(b.get('palette'), 3);
  });
}
