import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/session.dart';

/// 假网络：记下请求的地址，返回固定字节
class _FakeAdapter implements HttpClientAdapter {
  final urls = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    urls.add(options.uri.toString());
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('trimDir 超限时删最旧的，未超限不动', () async {
    final dir = await Directory.systemTemp.createTemp('trim');
    addTearDown(() => dir.delete(recursive: true));
    final now = DateTime.now();
    for (var i = 0; i < 5; i++) {
      final f = File('${dir.path}/f$i')..writeAsBytesSync(List.filled(100, 0));
      f.setLastModifiedSync(now.subtract(Duration(minutes: 5 - i))); // f0 最旧
    }
    await trimDir(dir, 500);
    expect(dir.listSync().length, 5);

    await trimDir(dir, 400); // 总 500 > 400：删到 ≤320，即只留最新的 3 个
    final names = dir.listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, {'f2', 'f3', 'f4'});
  });

  test('load 下载完能返回（不会自己等自己卡死），封面图床走 http，第二次从缓存拿', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final net = _FakeAdapter();
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    const url = 'https://img.wenku8.com/image/1/1158/1158s.jpg';
    expect(await store.load(url).timeout(const Duration(seconds: 2)), [1, 2, 3]);
    expect(net.urls, ['http://img.wenku8.com/image/1/1158/1158s.jpg']);
    expect(await store.load(url).timeout(const Duration(seconds: 2)), [1, 2, 3]);
    expect(net.urls, hasLength(1));
  });
}
