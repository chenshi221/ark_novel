import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/catalog.dart';

void main() {
  test('rankParam：分时间的榜单是「时间 + 榜单」，其他的只有榜单', () {
    expect(rankParam('visit', 'week'), 'weekvisit');
    expect(rankParam('vote', 'all'), 'allvote');
    expect(rankParam('size', 'week'), 'size');
    expect(rankParam('lastupdate', 'all'), 'lastupdate');
  });

  test('parseRank：每种榜单 × 时间都能还原（不分时间的榜单时间回到「总」）', () {
    for (final k in rankKinds) {
      for (final p in rankPeriods) {
        final (kind, period) = parseRank(rankParam(k.$2, p.$2));
        expect(kind, k.$2);
        expect(period, rankPeriodic.contains(k.$2) ? p.$2 : 'all');
      }
    }
  });

  test('parseRank：空的、认不出的用第一个榜单和「总」', () {
    expect(parseRank(''), (rankKinds.first.$2, 'all'));
    expect(parseRank('???'), (rankKinds.first.$2, 'all'));
  });
}
