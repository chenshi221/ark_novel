import 'dart:io';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_txt.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';

String fixture(String name) => File('test/data/wenku8/fixtures/$name').readAsStringSync();

CatVolume vol(String title, Map<String, String> chapters) => CatVolume(title: title, chapters: [for (final e in chapters.entries) CatChapter(title: e.value, cid: e.key)]);

void main() {
  // 和 OVERLORD 网站目录一样的卷名、章名
  final catalogue = [
    vol('第一卷', {'1': 'prologue', '2': '第一章 开始与结束', '3': '第二章 楼层守护者', '4': 'EPILOGUE', '5': '后记', '6': '插图'}),
    vol('第二卷 黑暗战士', {'7': 'prologue', '8': '第一章 两个冒险者', '9': 'EPILOGUE', '10': '后记', '11': '插图'}),
  ];

  test('按网站目录拆章：cid 对上，插图章没有正文', () {
    final texts = Wenku8Txt.byCatalogue(fixture('txt_book.txt'), catalogue);
    expect(texts.keys, ['1', '2', '3', '4', '5', '7', '8', '9', '10']);
    expect(texts['2'], startsWith('１\n这个名词是'));
    expect(texts['7'], startsWith('台版 转自 轻之国度'));
  });

  test('横幅、页脚、分隔行不进正文；正文里提到文库的段落保留', () {
    final texts = Wenku8Txt.byCatalogue(fixture('txt_book.txt'), catalogue);
    final all = texts.values.join('\n');
    expect(all, isNot(contains('Www.WenKu8.Com')));
    expect(all, isNot(contains('◆◇')));
    expect(all, isNot(contains('<OVERLORD')));

    final t = Wenku8Txt.byCatalogue('第一卷 prologue\n    她在轻小说文库读到这本书。\n    ★☆★☆\n', catalogue);
    expect(t['1'], '她在轻小说文库读到这本书。');
  });

  test('标题里的实体、大小写、空白都能对上；没缩进的正文行不会被当成标题', () {
    final cat = [
      vol('第十卷 谋略的统治者', {'75070': '第一章 安兹‧乌尔‧恭魔导国'}),
    ];
    final t = Wenku8Txt.byCatalogue('第十卷 谋略的统治者  第一章 安兹&#8231;乌尔&#8231;恭魔导国\n    正文&#10084;\n不缩进的一行，短篇也没关系\n', cat);
    expect(t['75070'], '正文&#10084;\n不缩进的一行，短篇也没关系'); // 正文的实体在 decode 时统一解开
  });

  test('GBK 解码并解开实体', () {
    final bytes = Uint8List.fromList(const GbkCodec().encode('安兹&#8231;乌尔&#10084;'));
    expect(Wenku8Txt.decode(bytes), '安兹‧乌尔❤');
    expect(Wenku8Txt.fullBookUrl('1592', node: 2), 'https://dl.wenku8.com/down.php?type=txt&node=2&id=1592');
  });
}
