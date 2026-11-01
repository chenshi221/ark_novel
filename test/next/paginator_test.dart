import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reader/paginator.dart';
import 'package:ark_novel/next/reader/reader_body.dart' show readerStrut;
import 'package:ark_novel/next/reader/reader_page.dart' show formatChapter, halfWidth;

void main() {
  const style = TextStyle(fontSize: 16, height: 1.5);
  final text = List.generate(300, (i) => '这是第$i行文字，用来测试分页。').join('\n');

  test('切成多页，起点递增且从 0 开始', () {
    final starts = paginate(text, style, const Size(200, 300));
    expect(starts.first, 0);
    expect(starts.length, greaterThan(5));
    for (var i = 1; i < starts.length; i++) {
      expect(starts[i], greaterThan(starts[i - 1]));
    }
    expect(starts.last, lessThan(text.length));
  });

  test('页面更大页数更少', () {
    final small = paginate(text, style, const Size(200, 300)).length;
    final big = paginate(text, style, const Size(200, 600)).length;
    expect(big, lessThan(small));
  });

  test('偏移能找回所在页', () {
    final starts = paginate(text, style, const Size(200, 300));
    expect(pageOfOffset(starts, 0), 0);
    expect(pageOfOffset(starts, starts[3]), 3);
    expect(pageOfOffset(starts, starts[3] + 1), 3);
    expect(pageOfOffset(starts, text.length), starts.length - 1);
  });

  test('章节标题：第一页给标题让出高度，后面每页照常', () {
    final head = headingHeight('第一章 很长很长的标题', style, 200);
    expect(head, greaterThan(16 * 1.35));
    final plain = paginate(text, style, const Size(200, 300));
    final titled = paginate(text, style, const Size(200, 300), firstTop: head);
    expect(titled[1], lessThan(plain[1]));
    expect(titled.length, greaterThanOrEqualTo(plain.length));
    expect(headingHeight('  ', style, 200), 0);
  });

  test('空文本只有一页', () => expect(paginate('', style, const Size(200, 300)), [0]));

  test('章节格式化：每段两个全角空格缩进，去掉空行和多余空白', () {
    expect(formatChapter('   第一段\n\n  第二段  \n\n'), '　　第一段\n　　第二段');
    expect(formatChapter(''), '');
  });

  test('全角英文、数字转半角，长度不变；中文标点和缩进不动', () {
    const raw = '「Ｄｉｖｅ　Ｍａｓｓｉｖｅｌｙ」的ＤＭＭＯ－ＲＰＧ，第１章！　　中文';
    expect(halfWidth(raw), '「Dive Massively」的DMMO-RPG，第1章！　　中文');
    expect(halfWidth(raw).length, raw.length);
  });

  test('固定行高：带颜色的文字所在的行和别的行一样高，每页行数和切页时算的一致', () {
    final strut = readerStrut(style);
    final plain = TextPainter(text: TextSpan(text: List.filled(80, '一二三四五六七八九十').join(), style: style), textDirection: TextDirection.ltr, strutStyle: strut)..layout(maxWidth: 200);
    final colored = TextPainter(
      text: TextSpan(style: style, children: [const TextSpan(text: '一二三四五六'), TextSpan(text: '七八九十一二三四五六七八九十', style: style.copyWith(color: const Color(0xFFE53935), backgroundColor: const Color(0x22E53935))), TextSpan(text: List.filled(60, '一二三四五六七八九十').join())]),
      textDirection: TextDirection.ltr,
      strutStyle: strut,
    )..layout(maxWidth: 200);
    final a = plain.computeLineMetrics().map((l) => l.height.toStringAsFixed(2)).toSet();
    final b = colored.computeLineMetrics().map((l) => l.height.toStringAsFixed(2)).toSet();
    expect(a, hasLength(1));
    expect(b, a);
  });
}

