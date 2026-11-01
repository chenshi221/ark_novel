import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/next/cover_color.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/read_state.dart';
import 'package:ark_novel/next/pages/volumes_page.dart';
import 'package:ark_novel/next/progress.dart';
import 'package:ark_novel/next/volumes.dart';

CatVolume vol(String t, List<String> chapters) => CatVolume(title: t, chapters: [for (final c in chapters) CatChapter(title: c.startsWith('i') ? '插图' : '第$c章', cid: c)]);

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_vol_test').path);
    await Hive.openBox('session');
  });

  test('一卷的正文章节全读了才算读完（插图章不算），标回未读就不算了', () async {
    await Volumes.saveCatalogue('1', [vol('第一卷', ['i1', 'a', 'b']), vol('第二卷', ['c'])]);
    expect(Volumes.of('1').first.illus, 'i1');
    expect(Volumes.done('1'), isEmpty);

    await ReadState.setRead('1', ['a', 'b'], true);
    expect(Volumes.done('1').keys, ['第一卷']);
    expect(Volumes.allDone().single.$3.title, '第一卷');

    await ReadState.setRead('1', ['b'], false);
    expect(Volumes.done('1'), isEmpty);
  });

  test('卷封面：第一张是横版展开图（连书脊、封底）就用后面第一张竖着的', () async {
    final sizes = {'spread': const Size(2000, 700), 'cover': const Size(700, 1000), 'insert': const Size(700, 1000)};
    Future<Size> sizeOf(String url) async => sizes[url]!;
    expect(await chooseCover(['spread', 'cover', 'insert'], sizeOf), 'cover');
    expect(await chooseCover(['cover', 'spread'], sizeOf), 'cover');
    expect(await chooseCover(['spread'], sizeOf), 'spread'); // 全是横的就还用第一张
    expect(await chooseCover([], sizeOf), '');
  });

  test('封面背景色：取主色调、压低饱和度、调暗', () {
    final red = Uint8List.fromList([for (var i = 0; i < 16; i++) ...[220, 40, 40, 255]]);
    final hsl = HSLColor.fromColor(tintFrom(red));
    expect(hsl.hue, closeTo(0, 1));
    expect(hsl.saturation, closeTo(0.35, 0.01));
    expect(hsl.lightness, closeTo(0.38, 0.01));
    // 白底上的一点颜色不会被冲成纯灰
    final mostlyWhite = Uint8List.fromList([for (var i = 0; i < 15; i++) ...[250, 250, 250, 255], 40, 80, 220, 255]);
    expect(HSLColor.fromColor(tintFrom(mostlyWhite)).hue, closeTo(225, 20));
  });

  test('自选封面的裁剪框：写进地址再读出来；没有裁剪框原样返回', () {
    const url = 'https://pic.777743.xyz/1/1/1.jpg';
    expect(splitCrop(url), (url: url, crop: null));
    final r = splitCrop(withCrop(url, const Rect.fromLTWH(0.5, 0, 0.5, 1)));
    expect(r.url, url);
    expect(r.crop, const Rect.fromLTWH(0.5, 0, 0.5, 1));
    // 自动去白边的记成 #trim=，读出来一样
    final t = splitCrop(withCrop(url, const Rect.fromLTWH(0.1, 0, 0.8, 1), auto: true));
    expect(t.url, url);
    expect(t.crop, const Rect.fromLTWH(0.1, 0, 0.8, 1));
  });

  test('提升清晰度的标记 #sr：和裁剪框一起写、一起读，读出来的地址是干净的', () {
    const url = 'https://pic.777743.xyz/1/1/1.jpg';
    final cropped = withSr(withCrop(url, const Rect.fromLTWH(0.5, 0, 0.5, 1)), true);
    expect(wantsSr(cropped), isTrue);
    expect(splitCrop(cropped), (url: url, crop: const Rect.fromLTWH(0.5, 0, 0.5, 1)));
    expect(withSr(url, true), '$url#sr');
    expect(splitCrop(withSr(url, true)), (url: url, crop: null));
    expect(withSr(cropped, false), withCrop(url, const Rect.fromLTWH(0.5, 0, 0.5, 1)));
  });

  test('cropRgba 只取裁剪框里的像素', () {
    // 2x2：左边红、右边蓝，取右半边只剩蓝
    final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255, 0, 0, 255, 255]);
    expect(cropRgba(rgba, 2, 2, const Rect.fromLTWH(0.5, 0, 0.5, 1)), [0, 0, 255, 255, 0, 0, 255, 255]);
  });

  test('正在读第几卷：进度所在的卷读完了（手动标的）就往后找没读完的，全读完为 -1', () async {
    await Volumes.saveCatalogue('2', [vol('一', ['a']), vol('二', ['b']), vol('三', ['c'])]);
    expect(readingVolume('2'), -1); // 没读过
    await ReadingProgress.save('2', 'a', 0);
    expect(readingVolume('2'), 0);
    await ReadState.setRead('2', ['a'], true);
    expect(readingVolume('2'), 1);
    await ReadState.setRead('2', ['b', 'c'], true);
    expect(readingVolume('2'), -1);
  });

  test('清理图片时留下的卷封面：书架上显示的第一卷、手动挑过或裁过的；其余卷可以删', () async {
    await Volumes.saveCatalogue('5', [vol('一', ['i1', 'a']), vol('二', ['i2', 'b']), vol('三', ['i3', 'c']), vol('四', ['i4', 'd'])]);
    await Volumes.setCover('5', '一', 'u1');
    await Volumes.setCover('5', '二', 'u2');
    await Volumes.setCover('5', '三', 'u3', picked: true);
    await Volumes.setCover('5', '四', withCrop('u4', const Rect.fromLTWH(0, 0, 0.5, 1))); // 以前裁过的，没有标记
    expect(Volumes.keptCovers(['5']), unorderedEquals(['u1', 'u3', withCrop('u4', const Rect.fromLTWH(0, 0, 0.5, 1))]));
    await Volumes.setCover('5', '二', withCrop('u2', const Rect.fromLTWH(0.1, 0, 0.8, 1), auto: true)); // 自动去白边的不算手动挑的
    expect(Volumes.keptCovers(['5']), isNot(contains(withCrop('u2', const Rect.fromLTWH(0.1, 0, 0.8, 1), auto: true))));
    expect(Volumes.keptCovers([]), isNot(contains('u1'))); // 不在书架上了，第一卷也不留
    await Volumes.resetCover('5', '三');
    expect(Volumes.keptCovers(['5']), isNot(contains('u3')));
  });
}
