import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reader/reader_body.dart';

void main() {
  Future<void> pump(WidgetTester t, {required double width, required bool dual, required ReaderNav nav, required List<int> offsets}) async {
    t.view.physicalSize = Size(width, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final text = List.generate(400, (i) => '　　这是第$i段，用来凑够很多页的正文内容。').join('\n');
    final style = const TextStyle(fontSize: 18, height: 1.8);
    final c = Chapter(text: text, images: const [], marks: const []);
    await t.pumpWidget(
      MaterialApp(
        home: PagedBody(
          chapter: c,
          spanOf: (a, b) => TextSpan(text: c.text.substring(a, b), style: style),
          style: style,
          margin: 20,
          title: '标题',
          curl: false,
          dual: dual,
          background: Colors.white,
          color: Colors.black,
          startOffset: 0,
          onOffset: offsets.add,
          onEnd: () {},
          onPrev: null,
          onNext: null,
          wrap: (w) => w,
          onTapZone: () {},
          onMark: (_) {},
          hasSelection: () => false,
          nav: nav,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('宽屏双页：一屏两页，键盘翻页一次前进一屏', (t) async {
    final nav = ReaderNav();
    final offsets = <int>[];
    await pump(t, width: 1200, dual: true, nav: nav, offsets: offsets);
    expect(find.textContaining('1/'), findsOneWidget);
    expect(find.textContaining('2/'), findsOneWidget);
    nav.next!();
    await t.pumpAndSettle();
    expect(find.textContaining('3/'), findsOneWidget);
    expect(find.textContaining('4/'), findsOneWidget);
    expect(offsets.last, greaterThan(0));
    nav.prev!();
    await t.pumpAndSettle();
    expect(find.textContaining('1/'), findsOneWidget);
  });

  testWidgets('窄屏或关闭双页时仍是单页', (t) async {
    await pump(t, width: 600, dual: true, nav: ReaderNav(), offsets: []);
    expect(find.textContaining('2/'), findsNothing);
    await pump(t, width: 1200, dual: false, nav: ReaderNav(), offsets: []);
    expect(find.textContaining('2/'), findsNothing);
  });
}
