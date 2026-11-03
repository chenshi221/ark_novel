import 'dart:typed_data';

import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按顺序返回预设状态码，记下每次请求真正发出的路径和时间，以及同时在途的最大数量。
class _Seq implements HttpClientAdapter {
  _Seq(this.statuses);

  final List<int> statuses;
  final paths = <String>[];
  final sent = <DateTime>[];
  int _active = 0, maxActive = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.path);
    sent.add(DateTime.now());
    if (++_active > maxActive) maxActive = _active;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _active--;
    return ResponseBody.fromBytes(Uint8List(0), statuses.removeAt(0));
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const pause = Duration(milliseconds: 500);

  (Wenku8Client, _Seq) make(List<int> statuses) {
    final adapter = _Seq(statuses);
    return (
      Wenku8Client(baseUrl: () => 'https://x', charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = adapter, rateLimitPause: pause),
      adapter,
    );
  }

  test('429：所有请求暂停，读页面的自动重试', () async {
    final (client, adapter) = make([429, 200, 200]);
    await Future.wait([client.getPage('https://x/a'), client.getPage('https://x/b')]);
    expect(adapter.sent.length, 3);
    expect(adapter.sent[1].difference(adapter.sent[0]), greaterThanOrEqualTo(pause));
  });

  test('一直 429：试满 3 次后抛出', () async {
    final (client, adapter) = make([429, 429, 429, 200]);
    await expectLater(client.getPage('https://x/a'), throwsA(isA<Wenku8HttpException>()));
    expect(adapter.sent.length, 3);
  });

  test('其他错误不暂停也不重试', () async {
    final (client, adapter) = make([500, 200]);
    await expectLater(client.getPage('https://x/a'), throwsA(isA<Wenku8HttpException>()));
    expect(adapter.sent.length, 1);
    await client.getPage('https://x/b');
    expect(adapter.sent[1].difference(adapter.sent[0]), lessThan(pause));
  });

  test('一次只发一个，后台间隔 1 秒，前台插队', () async {
    final (client, adapter) = make([200, 200, 200, 200]);
    final jobs = [for (final p in ['a', 'b', 'c']) runInBackground(() => client.getPage('https://x/$p'))];
    await Future<void>.delayed(const Duration(milliseconds: 100)); // a 已发出，b、c 在排队
    jobs.add(client.getPage('https://x/front'));
    await Future.wait(jobs);
    expect(adapter.paths.map((p) => p.split('/').last.split('?').first), ['a', 'front', 'b', 'c']);
    expect(adapter.maxActive, 1);
    // 限速器从派发时（_last）算间隔，这里量的是请求到达适配器的时间，中间有几微秒的抖动，所以留 5 毫秒误差
    expect(adapter.sent[3].difference(adapter.sent[2]), greaterThanOrEqualTo(const Duration(seconds: 1) - const Duration(milliseconds: 5)));
  });
}
