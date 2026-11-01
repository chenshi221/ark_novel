import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/chapter_list.dart';
import 'package:ark_novel/next/pages/bookshelf_page.dart';

void main() {
  test('三态筛选：0 不限，1 必须满足，2 必须不满足', () {
    expect(chapterTri(0, () => false), isTrue);
    expect(chapterTri(1, () => true), isTrue);
    expect(chapterTri(1, () => false), isFalse);
    expect(chapterTri(2, () => false), isTrue);
    expect(chapterTri(2, () => true), isFalse);
  });

  test('书架选项存取不丢字段', () {
    const o = ShelfOptions(sort: ShelfSort.random, reverse: true, display: 2, unread: 1, started: 2, cached: 1, bookmarked: 2, completed: 1);
    final back = ShelfOptions.fromMap(o.toMap());
    expect(back.toMap(), o.toMap());
    expect(back.filtering, isTrue);
    expect(const ShelfOptions().filtering, isFalse);
  });

  test('目录选项存取不丢字段', () {
    const o = ChapterListOptions(unread: 1, bookmarked: 2, cached: 1, reverse: true, showIndex: true);
    expect(ChapterListOptions.fromMap(o.toMap()).toMap(), o.toMap());
    expect(const ChapterListOptions().filtering, isFalse);
  });
}
