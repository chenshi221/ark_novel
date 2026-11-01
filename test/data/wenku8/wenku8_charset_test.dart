import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_charset.dart';
import 'package:ark_novel/models/common/charset_type.dart';

void main() {
  group('percentEncode', () {
    test('GBK 编码每个字节', () {
      expect(Wenku8Charset.percentEncode('中', CharsetType.gbk), '%D6%D0');
      expect(Wenku8Charset.percentEncode('魔法', CharsetType.gbk), '%C4%A7%B7%A8');
    });

    test('Big5 编码每个字节，包括落在 ASCII 范围内的尾字节', () {
      expect(Wenku8Charset.percentEncode('中', CharsetType.big5Hkscs), '%A4%A4');
      expect(Wenku8Charset.percentEncode('發', CharsetType.big5Hkscs), '%B5%6F');
    });
  });

  test('percentEncodeNonAscii 保留 ASCII 原样', () {
    expect(Wenku8Charset.percentEncodeNonAscii('ab 中', CharsetType.gbk), 'ab %D6%D0');
  });

  test('decode 能还原 GBK 字节', () {
    final bytes = Uint8List.fromList([0xD6, 0xD0, 0x41]);
    expect(Wenku8Charset.decode(bytes, CharsetType.gbk), '中A');
  });

  group('withCharsetParam', () {
    test('已有查询参数时追加', () {
      expect(Wenku8Charset.withCharsetParam('https://x/a.php?id=1', CharsetType.gbk), 'https://x/a.php?id=1&charset=gbk');
    });

    test('没有查询参数时补上问号', () {
      expect(Wenku8Charset.withCharsetParam('https://x/index.php', CharsetType.big5Hkscs), 'https://x/index.php?&charset=big5');
    });
  });
}
