import 'dart:async';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/custom_exception.dart';

Future<void> _tail = Future.value();

/// 相邻两次加载至少隔这么久：网页一页带出好几个请求，连着开会被 Cloudflare 限流成 Access denied
const _gap = Duration(seconds: 1);

/// App 自己的请求被 Cloudflare 拦下时，改用不显示的网页加载同一地址并取整页 HTML。
/// 网页是真浏览器，Cloudflare 通常直接放行；cookie 和登录用的网页共用，登录状态自然带上。
/// 一次只开一个网页，其余排队。网页也过不去（一直停在验证页）就照旧抛 [CloudflareChallengeException]，让界面提示去验证。
Future<String> webFetch(String url, {String? referer, String proxy = ''}) {
  final result = _tail.then((_) => _load(url, referer, proxy));
  _tail = result.then<void>((_) {}, onError: (_) {}).then((_) => Future<void>.delayed(_gap));
  return result;
}

/// WebView 的代理是整个进程共用的，跟着设置走：请求页面和网页的出口才一致，清空设置后也不会留着旧代理（只有 Android 支持）。
Future<void> applyWebViewProxy(String proxy) async {
  if (!Platform.isAndroid) return;
  try {
    final controller = ProxyController.instance();
    if (proxy.isEmpty) {
      await controller.clearProxyOverride();
    } else {
      await controller.setProxyOverride(settings: ProxySettings(proxyRules: [ProxyRule(url: 'http://$proxy')]));
    }
  } catch (_) {}
}

Future<String> _load(String url, String? referer, String proxy) async {
  await applyWebViewProxy(proxy);
  final done = Completer<String>();
  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url), headers: referer == null ? null : {'Referer': referer}),
    // 只要 HTML，不下图片，少发请求
    initialSettings: InAppWebViewSettings(blockNetworkImage: true),
    onLoadStop: (c, _) async {
      final title = await c.getTitle() ?? '';
      // Cloudflare 的验证页过了会自己跳走，等下一次加载完成
      if (title.contains('Just a moment')) return;
      if (title.startsWith('Access denied')) {
        if (!done.isCompleted) done.completeError(Cloudflare403Exception(requestOptions: RequestOptions(path: url)));
        return;
      }
      final html = await c.evaluateJavascript(source: 'document.documentElement.outerHTML');
      if (!done.isCompleted && html is String) done.complete(html);
    },
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame != false && !done.isCompleted) done.completeError(DioException(requestOptions: RequestOptions(path: url), message: error.description));
    },
  );
  await view.run();
  try {
    return await done.future.timeout(const Duration(seconds: 20), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
  } finally {
    await view.dispose();
  }
}
