import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/cache.dart';

void main() {
  test('网页备份超过上限时删写入最早的，而不是键排序最靠前的', () async {
    Hive.init(Directory.systemTemp.createTempSync('ark_pages_test').path);
    await ChapterCache.open();
    await PageStore.put('zzz|first', 'x'); // 键排序最靠后，但写得最早
    for (var i = 0; i < 400; i++) {
      await PageStore.put('a|$i', 'x');
    }
    expect(await PageStore.get('zzz|first'), isNull);
    expect(await PageStore.get('a|0'), 'x');
    expect(await PageStore.get('a|399'), 'x');
  });
}
