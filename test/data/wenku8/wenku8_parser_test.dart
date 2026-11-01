import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/data/wenku8/wenku8_parser.dart';

String fixture(String name) => File('test/data/wenku8/fixtures/$name').readAsStringSync();

void main() {
  const base = 'https://www.wenku8.net';

  test('列表页：解析书名、封面、书号，跳过没有链接的条目', () {
    final list = Wenku8Parser.novelList(fixture('novel_list.html'), baseUrl: base);
    expect(list.map((e) => e.title), ['测试小说一', '测试小说二']);
    expect(list.map((e) => e.aid), ['1973', '2']);
    expect(list[0].imageUrl, 'https://img.wenku8.com/image/1/1973/1973s.jpg');
    expect(list[1].imageUrl, 'https://www.wenku8.net/modules/article/images/nocover.jpg');
  });

  test('列表页：总页数', () {
    expect(Wenku8Parser.maxPage(fixture('novel_list.html')), 37);
    expect(Wenku8Parser.maxPage('<html></html>'), 0);
  });

  test('目录：按卷分组章节', () {
    final volumes = Wenku8Parser.catalogue(fixture('catalogue.html'));
    expect(volumes.map((v) => v.title), ['第一卷 开始', '第二卷 继续']);
    expect(volumes[0].chapters.map((c) => c.title), ['序章', '第一章']);
    expect(volumes[0].chapters.map((c) => c.cid), ['100', '101']);
    expect(volumes[1].chapters.single.cid, '200');
  });

  test('正文：段落首行缩进，提取插图，去掉页脚', () {
    final content = Wenku8Parser.chapterContent(fixture('chapter.html'));
    expect(content.images, ['https://pic.wenku8.com/pictures/1/1973/100/1.jpg']);
    // 沿用旧行为：最后整体 trim 会去掉第一段的缩进（新阅读器会自己处理缩进）
    expect(content.text, startsWith('第一段第一行\n第一段第二行\n\n   第二段'));
    expect(content.text, isNot(contains('轻小说文库')));
  });

  test('正文：页面结构不对时抛出明确异常', () {
    expect(() => Wenku8Parser.chapterContent('<html></html>'), throwsA(isA<Wenku8UnexpectedPageException>()));
  });

  test('用户信息：按行取字段，没有邮箱链接时退回文本', () {
    final info = Wenku8Parser.userInfo(fixture('user_info.html'));
    expect(info.uid, '12345');
    expect(info.username, '测试者');
    expect(info.userLevel, '新手上路');
    expect(info.email, '未设置');
    expect(info.registerDate, '2020-01-01');
    expect(info.point, '30');
    expect(info.maxBookshelfNum, '500');
    expect(info.avatar, 'http://www.wenku8.net/avatar.jpg');
  });

  test('用户信息：拿到登录页等其他页面时抛出异常（用于判断会话失效）', () {
    expect(() => Wenku8Parser.userInfo(fixture('error.html')), throwsA(isA<Wenku8UnexpectedPageException>()));
  });

  test('错误页识别', () {
    expect(Wenku8Parser.isErrorPage(fixture('error.html')), isTrue);
    expect(Wenku8Parser.isErrorPage(fixture('novel_list.html')), isFalse);
  });

  test('书架：解析 bid、书号，跳过表头和页脚，按规则拼封面', () {
    final shelf = Wenku8Parser.bookshelf(fixture('bookshelf.html'), 3);
    expect(shelf.classId, '3');
    expect(shelf.list.map((e) => e.bid), ['9001', '9002']);
    expect(shelf.list.map((e) => e.aid), ['1973', '12']);
    expect(shelf.list[0].img, 'https://img.wenku8.com/image/1/1973/1973s.jpg');
    expect(shelf.list[1].img, 'https://img.wenku8.com/image/0/12/12s.jpg');
  });

  test('详情：正常书籍', () {
    final d = Wenku8Parser.novelDetail(fixture('novel_detail.html'));
    expect(d.title, '测试小说一');
    expect(d.author, '作者甲');
    expect(d.status, '连载中');
    expect(d.lastUpdate, '2024-01-02');
    expect(d.isDelisted, isFalse);
    expect(d.tags, ['魔法', '校园', '恋爱']);
    expect(d.heat, 'A级');
    expect(d.trending, 'B级');
    expect(d.introduce, '第一行\n第二行');
    expect(d.isAnimated, isTrue);
    expect(d.imgUrl, 'https://img.wenku8.com/image/1/1973/1973s.jpg');
  });

  test('详情：已下架书籍', () {
    final d = Wenku8Parser.novelDetail(fixture('novel_detail_delisted.html'));
    expect(d.isDelisted, isTrue);
    expect(d.heat, isNull);
    expect(d.trending, isNull);
    expect(d.introduce, '该书已下架的说明');
    expect(d.isAnimated, isFalse);
  });

  test('书评列表', () {
    final c = Wenku8Parser.comments(fixture('comments.html')).single;
    expect(c.rid, '555');
    expect(c.content, '好看！');
    expect(c.replyCount, '3');
    expect(c.viewCount, '120');
    expect(c.userName, '读者乙');
    expect(c.uid, '42');
    expect(c.time, '2024-02-03 10:00');
  });

  test('回复列表：跳过头部 3 个和尾部 2 个 table', () {
    final replies = Wenku8Parser.replies(fixture('replies.html'));
    expect(replies.map((r) => r.userName), ['楼主', '读者丙']);
    expect(replies.map((r) => r.uid), ['7', '8']);
    expect(replies[0].time, '2024-02-03 10:00');
    expect(replies[1].content, '正文二');
  });
}
