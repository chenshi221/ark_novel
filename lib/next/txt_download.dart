import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/wenku8/wenku8_txt.dart';
import 'session.dart';

/// 从 dl.wenku8.com 下载全本 TXT（下载站不检查登录，受限书也能拿到）。
class TxtDownloader {
  TxtDownloader(this._dio);

  final Dio _dio;

  /// 节点 1 不行换节点 2；都不行抛最后一个错误。
  Future<Uint8List> fetch(String aid) async {
    Object? error;
    for (final node in [1, 2]) {
      try {
        final r = await _dio.get<List<int>>(Wenku8Txt.fullBookUrl(aid, node: node));
        final data = r.data;
        if (data != null && data.isNotEmpty) {
          final head = String.fromCharCodes(data.take(64)).trimLeft().toLowerCase();
          if (head.startsWith('<!doctype') || head.startsWith('<html')) {
            error = Exception('下载节点 $node 返回了错误页');
            continue;
          }
          return data is Uint8List ? data : Uint8List.fromList(data);
        }
        error = Exception('下载到的 TXT 是空的');
      } catch (e) {
        error = e;
      }
    }
    throw error!;
  }
}

final txtDownloaderProvider = Provider<TxtDownloader>((ref) {
  final store = ref.watch(sessionStoreProvider);
  ref.watch(proxyProvider);
  final dio = Dio(
    BaseOptions(
      responseType: ResponseType.bytes,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 120),
      headers: {'User-Agent': store.userAgent, 'Accept': '*/*'},
    ),
  )..httpClientAdapter = store.adapter();
  return TxtDownloader(dio);
});
