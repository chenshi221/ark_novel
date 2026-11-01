import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_app_api.dart';

String fixture(String name) => File('test/data/wenku8/fixtures/$name').readAsStringSync();

/// 按请求返回预设响应的假适配器（测试不联网），同时记录每个请求，方便断言端点回退和请求体。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _text(String value, {int status = 200}) => ResponseBody.fromBytes(utf8.encode(value), status);

ResponseBody _html([String value = '<!DOCTYPE html><html><body>Bad request.</body></html>']) => _text(value);

/// 从表单体里还原 base64 编码的 action，确认发出去的确实是这条接口请求。
String _actionOf(RequestOptions options) {
  final body = options.data as String;
  final request = RegExp(r'request=([^&]*)').firstMatch(body)!.group(1)!;
  return utf8.decode(base64Decode(request));
}

Wenku8AppApi _api(_FakeAdapter adapter) =>
    Wenku8AppApi(dio: Dio()..httpClientAdapter = adapter, endpoints: const ['https://relay.test/android.php', 'https://app.test/android.php']);

void main() {
  test('默认端点：社区中继在前，官方接口兜底；appver 固定 1.13', () {
    expect(Wenku8AppApi.appVer, '1.13');
    expect(Wenku8AppApi.defaultEndpoints, ['https://wenku8-relay.mewx.org/android.php', 'http://app.wenku8.com/android.php']);
  });

  test('requestBody：appver、base64 action、毫秒 timetoken 齐全且可逆', () {
    const action = 'action=book&do=text&aid=1592&cid=123&t=0';
    final body = Wenku8AppApi.requestBody(action);

    expect(body, startsWith('&appver=1.13&request='));
    final match = RegExp(r'^&appver=([^&]*)&request=([^&]+)&timetoken=(\d+)$').firstMatch(body);
    expect(match, isNotNull);
    expect(match!.group(1), Wenku8AppApi.appVer);
    expect(utf8.decode(base64Decode(match.group(2)!)), action);
    // 毫秒时间戳（2020 年之后）
    expect(int.parse(match.group(3)!), greaterThan(1577836800000));
  });

  test('目录：第一个端点返回 HTML 时按顺序回退，请求带 App UA 和表单头', () async {
    final adapter = _FakeAdapter((options) => options.uri.host == 'relay.test' ? _html() : _text(fixture('api_catalogue.xml')));
    final volumes = await _api(adapter).catalogue('1592');

    // 两个端点都试过，第二个拿到数据
    expect(adapter.requests.map((e) => e.uri.host), ['relay.test', 'app.test']);
    final request = adapter.requests.last;
    expect(request.method, 'POST');
    expect(_actionOf(request), 'action=book&do=list&aid=1592&t=0');
    expect(request.contentType, Headers.formUrlEncodedContentType);
    expect(request.headers['User-Agent'], 'Dalvik/2.1.0 (Linux; U; Android 7.1.2; unknown Build/NZH54D)');
    expect(request.headers['Accept'], '*/*');
    // 按字节接收、超时时间与协议一致
    expect(request.responseType, ResponseType.bytes);
    expect(request.connectTimeout, const Duration(seconds: 12));
    expect(request.receiveTimeout, const Duration(seconds: 30));

    expect(volumes.map((v) => v.title), ['第一卷 不死者之王', '第二卷 黑暗战士']);
    expect(volumes[0].chapters.map((c) => c.title), ['第一章 火之七日', '第二章 & 测试']);
    expect(volumes[0].chapters.map((c) => c.cid), ['123', '124']);
    expect(volumes[1].chapters.single.title, '第一章 漆黑');
    expect(volumes[1].chapters.single.cid, '125');
  });

  test('目录：第一个端点网络异常时也回退到下一个端点', () async {
    final adapter = _FakeAdapter((options) {
      if (options.uri.host == 'relay.test') throw DioException(requestOptions: options, type: DioExceptionType.connectionError);
      return _text(fixture('api_catalogue.xml'));
    });

    final volumes = await _api(adapter).catalogue('1592');

    expect(volumes, hasLength(2));
    expect(adapter.requests, hasLength(2));
  });

  test('目录：接口返回空目录时抛 Wenku8AppApiException', () async {
    final adapter = _FakeAdapter((_) => _text('<?xml version="1.0" encoding="utf-8"?><package></package>'));

    await expectLater(_api(adapter).catalogue('1592'), throwsA(isA<Wenku8AppApiException>()));
    // 两个端点都判定为格式不对
    expect(adapter.requests, hasLength(2));
  });

  test('正文：抽取图片、过滤分隔行和页脚行', () async {
    final adapter = _FakeAdapter((_) => _text(fixture('api_chapter.txt')));
    final content = await _api(adapter).chapter('1592', '123');

    expect(content.images, ['https://img.wenku8.com/image/1/1592/1592.jpg', 'https://img.wenku8.com/image/1/1592/1592b.jpg']);
    expect(content.text, '这是第一段正文。\n第二段正文，包含符号 & 和换行。');
    expect(_actionOf(adapter.requests.single), 'action=book&do=text&aid=1592&cid=123&t=0');
  });

  test('正文：CRLF 分行、去空行', () async {
    final adapter = _FakeAdapter((_) => _text('第一段\r\n\r\n◆◇◆◇\r\n第二段\r\n'));
    final content = await _api(adapter).chapter('1', '2');

    expect(content.text, '第一段\n第二段');
    expect(content.images, isEmpty);
  });

  test('正文：只有标点的台词保留，页脚只去末尾', () async {
    final adapter = _FakeAdapter((_) => _text('「……」\r\n！？\r\n……\r\n她在轻小说文库读到这本书。\r\n◆◇◆◇\r\n轻小说文库 www.wenku8.com\r\n'));
    final content = await _api(adapter).chapter('1', '2');

    expect(content.text, '「……」\n！？\n……\n她在轻小说文库读到这本书。');
  });

  test('正文：只有分隔行和页脚时抛错', () async {
    final adapter = _FakeAdapter((_) => _text('★☆★☆\r\n◆◇◆◇\r\n轻小说文库 www.wenku8.com\r\n'));

    await expectLater(_api(adapter).chapter('1', '2'), throwsA(isA<Wenku8AppApiException>()));
  });

  test('正文：接口返回 HTML / Welcome 时判为失败，抛错信息包含每个端点', () async {
    final adapter = _FakeAdapter((_) => _html());
    try {
      await _api(adapter).chapter('1', '2');
      fail('HTML 错误页应当抛异常');
    } on Wenku8AppApiException catch (e) {
      expect(e.message, contains('relay.test'));
      expect(e.message, contains('app.test'));
    }
    expect(adapter.requests, hasLength(2));

    final welcome = _FakeAdapter((_) => _text('Welcome'));
    await expectLater(_api(welcome).catalogue('1'), throwsA(isA<Wenku8AppApiException>()));
    expect(welcome.requests, hasLength(2));
  });
}
