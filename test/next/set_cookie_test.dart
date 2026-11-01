import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/net_io.dart';

void main() {
  test('系统网络栈合并成一条的 Set-Cookie 拆回多条，expires 里的逗号不拆', () {
    const folded = 'PHPSESSID=abc; path=/, jieqiUserInfo=x%3Dy; expires=Thu, 01 Jan 2026 00:00:00 GMT; path=/, jieqiVisitInfo=1; path=/';
    expect(splitSetCookie([folded]), [
      'PHPSESSID=abc; path=/',
      'jieqiUserInfo=x%3Dy; expires=Thu, 01 Jan 2026 00:00:00 GMT; path=/',
      'jieqiVisitInfo=1; path=/',
    ]);
    expect(splitSetCookie(['a=1', 'b=2']), ['a=1', 'b=2']);
  });
}
