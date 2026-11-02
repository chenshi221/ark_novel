import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../../models/common/charset_type.dart';
import '../../models/custom_exception.dart';
import 'wenku8_charset.dart';
import 'wenku8_exceptions.dart';

/// 访问 wenku8 的 HTTP 客户端。
///
/// 只负责"发请求 + 处理编码/重定向/Cloudflare + 管理 cookie"，不依赖 GetX 或本地存储：
/// 节点地址和编码通过构造参数里的函数按需读取，方便测试和以后替换状态管理。
class Wenku8Client {
  Wenku8Client({required this.baseUrl, required this.charset, required Map<String, String> headers, Dio? dio, CookieJar? cookieJar, this.challengeFallback})
    : _cookieJar = cookieJar ?? CookieJar() {
    this.dio = (dio ?? Dio())
      ..options = BaseOptions(
        headers: headers,
        responseType: ResponseType.bytes,
        followRedirects: false,
        validateStatus: (status) => status != null,
        connectTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 25),
      )
      ..interceptors.add(_ThrottleInterceptor())
      ..interceptors.add(_CloudflareInterceptor());
    // 浏览器自己管理 cookie，CookieManager 在网页环境会断言失败（网页预览的 cookie 由转发程序保存）
    if (!kIsWeb) this.dio.interceptors.add(CookieManager(_cookieJar));
  }

  /// 当前节点地址，例如 `https://www.wenku8.net`
  final String Function() baseUrl;

  /// 当前使用的页面编码
  final CharsetType Function() charset;

  final CookieJar _cookieJar;

  late final Dio dio;

  /// GET 页面被 Cloudflare 验证或 403 拦下时改用它取页面（原生 App 里是不显示的网页），返回解码好的 HTML
  final Future<String> Function(String url, {String? referer})? challengeFallback;

  /// 把登录后拿到的 cookie 字符串（`a=1;b=2`）写入 cookie jar，对 [hosts] 里的每个节点都生效。
  Future<void> restoreCookie(String cookie, Iterable<String> hosts) async {
    final cookies = cookie.split(';').map((e) => e.trim()).where((e) => e.contains('=')).map((e) {
      final kv = e.split('=');
      // dart:io 的 Cookie 不允许值里有空格、引号、逗号、分号、反斜杠（例如阅读记录 cookie 里的逗号），转义后再放进去
      return Cookie(kv[0], kv.sublist(1).join('=').replaceAllMapped(RegExp(r'[ ",;\\]'), (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}'));
    }).toList();
    for (final host in hosts) {
      await _cookieJar.saveFromResponse(Uri.parse(host), cookies);
    }
  }

  Future<void> clearCookie() => _cookieJar.deleteAll();

  /// 导出 cookie jar 里会发给 [host] 的 cookie（名字 → 值），用来把服务端续期过的 cookie 存回本地。
  Future<Map<String, String>> exportCookies(String host) async => {for (final c in await _cookieJar.loadForRequest(Uri.parse(host))) c.name: c.value};

  /// GET 一个页面并按当前编码解码成字符串。
  ///
  /// [charsetParam] 为 false 且当前是 GBK（网站默认编码）时不追加 `charset` 参数：上游项目发现带这个参数的书架、榜单、
  /// 详情、目录、正文请求会被 Cloudflare 的规则拦成 403；繁体（Big5）必须带参数，否则返回的还是 GBK 页面。
  /// [referer] 给目录、正文请求带上来源页，和浏览器行为一致。
  Future<String> getPage(String url, {bool charsetParam = true, String? referer}) async {
    final currentCharset = charset();
    final target = charsetParam || currentCharset != CharsetType.gbk ? Wenku8Charset.withCharsetParam(url, currentCharset) : url;
    final Uint8List bytes;
    try {
      final response = await dio.get(target, options: referer == null ? null : Options(headers: {'Referer': referer}));
      bytes = await _followRedirect(response);
    } on DioException catch (e) {
      // 书架这类页面不出验证，直接 403 拒绝不像浏览器的请求，也交给网页再试
      if (e is! CloudflareChallengeException && e is! Cloudflare403Exception) rethrow;
      final fallback = challengeFallback;
      if (fallback == null) rethrow;
      return fallback(target, referer: referer);
    }
    return Wenku8Charset.decode(bytes, currentCharset);
  }

  /// 以 `application/x-www-form-urlencoded` 提交表单，返回解码后的页面。
  ///
  /// [data] 可以是 Map（由 dio 编码），也可以是已经编码好的字符串。
  Future<String> postForm(String url, Object? data) async {
    final currentCharset = charset();
    final response = await dio.post(
      url,
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    _checkStatus(response);
    return Wenku8Charset.decode(response.data as Uint8List, currentCharset);
  }

  /// 4xx/5xx 不是页面，抛出让调用方走"网络问题"分支（403 已由 Cloudflare 拦截器处理）。
  void _checkStatus(Response response) {
    final status = response.statusCode ?? 0;
    if (status >= 400) throw Wenku8HttpException(status);
  }

  /// wenku8 会用 3xx 跳转（例如跳到登录页）。dio 关闭了自动跳转，这里手动跟随，
  /// 好让解析层拿到最终页面并判断出"未登录"等情况。
  /// - location 可能是相对路径（`userdetail.php`、`/login.php`）或绝对地址，基于当前请求地址解析
  /// - 最多跟随 [maxRedirects] 次，防止重定向死循环
  Future<Uint8List> _followRedirect(Response response, {int maxRedirects = 5}) async {
    var current = response;
    for (var i = 0; i < maxRedirects; i++) {
      final status = current.statusCode;
      if (status == null || status < 300 || status >= 400) break;
      final location = current.headers.value('location');
      if (location == null || location.isEmpty) break;
      current = await dio.getUri(current.requestOptions.uri.resolve(location));
    }
    _checkStatus(current);
    return current.data as Uint8List;
  }
}

class _CloudflareInterceptor extends Interceptor {
  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    // 验证页本身也是 403，先认出来，免得当成被封
    final cfMitigated = response.headers['cf-mitigated'];
    if (cfMitigated != null && cfMitigated.contains('challenge')) {
      handler.reject(CloudflareChallengeException(requestOptions: response.requestOptions));
      return;
    }
    if (response.statusCode == 403) {
      handler.reject(Cloudflare403Exception(requestOptions: response.requestOptions));
      return;
    }
    handler.next(response);
  }
}

/// 全局限流：同时最多 4 个请求在途，相邻请求至少间隔 120 毫秒，避免触发 Cloudflare 的速率限制。
class _ThrottleInterceptor extends Interceptor {
  static const _maxActive = 4;
  static const _gap = Duration(milliseconds: 120);

  int _active = 0;
  DateTime _nextAllowed = DateTime.fromMillisecondsSinceEpoch(0);
  final _waiters = Queue<Completer<void>>();

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (_active >= _maxActive) {
      final c = Completer<void>();
      _waiters.add(c);
      try {
        await c.future;
      } catch (_) {
        _waiters.remove(c);
        rethrow;
      }
    } else {
      _active++;
    }
    options.extra['throttled'] = true;

    try {
      final now = DateTime.now();
      final scheduled = _nextAllowed.isAfter(now) ? _nextAllowed : now;
      _nextAllowed = scheduled.add(_gap);
      final wait = scheduled.difference(now);
      if (!wait.isNegative && wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      handler.next(options);
    } catch (e) {
      _release(options);
      if (e is DioException) {
        handler.reject(e);
      } else {
        rethrow;
      }
    }
  }

  void _release(RequestOptions options) {
    if (options.extra.remove('throttled') != true) return;
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _active--;
    }
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _release(response.requestOptions);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _release(err.requestOptions);
    handler.next(err);
  }
}
