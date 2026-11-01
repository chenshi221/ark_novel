import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/settings.dart';

void main() {
  test('ReaderPrefs.dim 默认不遮，copyWith 只改 dim', () {
    const p = ReaderPrefs();
    expect(p.dim, 0);
    final q = p.copyWith(dim: 0.4);
    expect(q.dim, 0.4);
    expect(q.fontSize, p.fontSize);
    expect(q.copyWith(fontSize: 20).dim, 0.4);
  });
}
