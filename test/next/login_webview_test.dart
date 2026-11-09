import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/pages/login_webview_page.dart';

void main() {
  test('自动填表只认同一站点和它的子域名，不认只是后缀相同的域名', () {
    expect(isSameSite('wenku8.net', 'wenku8.net'), true);
    expect(isSameSite('www.wenku8.net', 'wenku8.net'), true);
    expect(isSameSite('evilwenku8.net', 'wenku8.net'), false);
    expect(isSameSite('wenku8.net.evil.com', 'wenku8.net'), false);
    expect(isSameSite('xwenku8.net', 'wenku8.net'), false);
  });
}
