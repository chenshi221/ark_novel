import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reader/paginator.dart';

void main() {
  test('按句号切句，引号并入句尾，太短的并入下一句', () {
    const text = '他说：“走吧。”然后离开了房间。\n哦。好的，我知道了。';
    final out = [for (final (s, e) in splitSentences(text)) text.substring(s, e)];
    expect(out, ['他说：“走吧。”', '然后离开了房间。', '哦。好的，我知道了。']);
  });

  test('没有句末标点也要读到结尾', () {
    const text = '最后一句没有标点';
    expect([for (final (s, e) in splitSentences(text)) text.substring(s, e)], [text]);
  });
}
