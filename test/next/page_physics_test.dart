import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reader/page_physics.dart';

void main() {
  group('松手后停在哪一页', () {
    int target(double current, double velocity, {double? from = 0}) => SwipePagePhysics.targetPage(current: current, from: from, velocity: velocity, viewport: 400);

    test('拖过一小段就翻页，只碰一下弹回', () {
      expect(target(40 / 400, 0), 1);
      expect(target(10 / 400, 0), 0);
      expect(target(2 - 40 / 400, 0, from: 2), 1);
    });

    test('甩一下按方向翻；往回甩回到原页', () {
      expect(target(5 / 400, 800), 1);
      expect(target(60 / 400, -800), 0);
    });

    test('一次最多翻一页', () {
      expect(target(0.9, 2000), 1);
      expect(target(1.6, 0), 2); // 拖过一整页的极端情况：停在最近的一页
    });

    test('翻页距离有上下限', () {
      expect(SwipePagePhysics.commitDistance(200), 24);
      expect(SwipePagePhysics.commitDistance(2000), 56);
    });
  });

  testWidgets('PageView 里慢慢拖 60 像素（含 18 像素起拖距离）松手翻到下一页，拖 8 像素弹回', (tester) async {
    final controller = PageController();
    double? from;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification) from = n.dragDetails == null ? null : controller.page;
              return false;
            },
            child: PageView.builder(
              controller: controller,
              pageSnapping: false,
              physics: SwipePagePhysics(origin: () => from, parent: const ClampingScrollPhysics()),
              itemCount: 5,
              itemBuilder: (context, i) => Center(child: Text('页$i')),
            ),
          ),
        ),
      ),
    );
    await tester.timedDrag(find.byType(PageView), const Offset(-8, 0), const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    await tester.timedDrag(find.byType(PageView), const Offset(-60, 0), const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(controller.page, 1);
    await tester.timedDrag(find.byType(PageView), const Offset(60, 0), const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(controller.page, 0);
  });
}
