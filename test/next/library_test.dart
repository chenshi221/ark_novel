import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/library.dart';

RemoteBook r(String bid, {int shelf = 0}) => (bid: bid, title: 't$bid', img: '', shelf: shelf);

void main() {
  test('改名候选：拆最后一组括号，全角半角都认，前面的括号留在名字里', () {
    expect(titleAlternatives('败北女角太多了！(败犬女主太多了！)'), ['败北女角太多了！', '败犬女主太多了！']);
    expect(titleAlternatives('86-不存在的战区-(86- Eighty Six -)'), ['86-不存在的战区', '86- Eighty Six']);
    expect(titleAlternatives('我们不可能成为恋人！绝对不行。(※似乎可行？)（我怎么可能成为你的恋人，不行不行！）'), ['我们不可能成为恋人！绝对不行。(※似乎可行？)', '我怎么可能成为你的恋人，不行不行！']);
    expect(titleAlternatives('OVERLORD不死者之王'), isEmpty);
    expect(titleAlternatives('(只有括号)'), isEmpty);
  });

  test('首次导入：网站书架 2~6 的书进同名分类，默认书架的不分类', () {
    final out = reconcile({}, {'1': r('b1'), '2': r('b2', shelf: 3)}, {}, now: 5, firstImport: true);
    expect(out['1']!.cats, isEmpty);
    expect(out['2']!.cats, ['shelf3']);
    expect(out['2']!.bid, 'b2');
    expect(reconcile({}, {'2': r('b2', shelf: 3)}, {}, now: 5)['2']!.cats, isEmpty);
  });

  test('网站上移出了的书本地也移出；只在本地的、刚加入还没推上去的留着', () {
    final local = {
      'synced': const LibBook(aid: 'synced', title: 'a', img: '', bid: 'x'),
      'local': const LibBook(aid: 'local', title: 'b', img: ''),
      'pending': const LibBook(aid: 'pending', title: 'c', img: '', bid: 'y'),
      'keep': const LibBook(aid: 'keep', title: 'd', img: '', cats: ['c1']),
    };
    final out = reconcile(local, {'keep': r('k')}, {'pending': 'add'}, now: 1);
    expect(out.keys.toSet(), {'local', 'pending', 'keep'});
    expect(out['keep']!.bid, 'k');
    expect(out['keep']!.cats, ['c1']);
  });

  test('本地刚移出、还没推到网站的书，不会被网站书架加回来', () {
    expect(reconcile({}, {'1': r('b1')}, {'1': 'remove'}, now: 1), isEmpty);
  });

  test('网站书架整个是空的（多半页面不对）时不删本地的书', () {
    final local = {'synced': const LibBook(aid: 'synced', title: 'a', img: '', bid: 'x')};
    expect(reconcile(local, {}, {}, now: 1).keys, ['synced']);
  });

  test('自己改的显示名称：和网站同步、存取都保留', () {
    const b = LibBook(aid: '1', title: '原名', img: '', bid: 'b1', name: '简称');
    final out = reconcile({'1': b}, {'1': r('b1')}, {}, now: 1);
    expect(out['1']!.shown, '简称');
    expect(LibBook.fromMap(out['1']!.toMap()).shown, '简称');
    expect(out['1']!.copyWith(title: '新名').shown, '简称');
    expect(const LibBook(aid: '2', title: '原名', img: '').shown, '原名');
  });
}
