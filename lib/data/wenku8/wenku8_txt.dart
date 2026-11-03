import 'dart:typed_data';

import '../../models/cat_volume.dart';
import '../../models/common/charset_type.dart';
import 'wenku8_charset.dart';

/// dl.wenku8.com 的全本 TXT：网站不给正文的受限书，下载站仍然给。纯函数，方便单测。
class Wenku8Txt {
  const Wenku8Txt._();

  /// 全本下载地址。[node] 是下载节点（1 / 2）。
  static String fullBookUrl(String aid, {int node = 1}) => 'https://dl.wenku8.com/down.php?type=txt&node=$node&id=$aid';

  /// GBK 解码；GBK 装不下的字符 TXT 里写成 `&#8231;` 这种实体，顺手解开。
  static String decode(Uint8List bytes) => decodeEntities(Wenku8Charset.decode(bytes, CharsetType.gbk));

  static final _entity = RegExp(r'&#([xX][0-9a-fA-F]+|\d+);');

  static String decodeEntities(String s) => s.replaceAllMapped(_entity, (m) {
    final v = m[1]!;
    final code = (v.startsWith('x') || v.startsWith('X')) ? int.tryParse(v.substring(1), radix: 16) : int.tryParse(v);
    return code == null || code < 0 || code > 0x10FFFF ? m[0]! : String.fromCharCode(code);
  });

  /// 纯分隔行（◆◇、★☆ 之类）
  static final _separator = RegExp(r'^[★☆◆◇=＝*＊~～\-—_·─━\s]+$');

  /// 按网站目录把全本 TXT 拆成每章正文：cid → 段落（`\n` 连接）。
  ///
  /// TXT 和网站出自同一份数据：每章标题顶格写成「卷名 章名」，正文行都有缩进，
  /// 所以拿网站目录拼出标题逐行对，不靠关键词猜。插图章在 TXT 里只有标题没有正文，不会出现在结果里。
  static Map<String, String> byCatalogue(String text, List<CatVolume> catalogue) {
    final heads = <String, List<String>>{};
    for (final v in catalogue) {
      for (final c in v.chapters) {
        (heads[_key('${v.title} ${c.title}')] ??= []).add(c.cid);
      }
    }
    final texts = <String, String>{};
    final paragraphs = <String>[];
    String? cid;
    void flush() {
      if (cid != null && paragraphs.isNotEmpty) texts[cid] = paragraphs.join('\n');
      paragraphs.clear();
    }

    for (final line in text.split(RegExp(r'\r\n|\r|\n'))) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (line == line.trimLeft()) {
        final hits = heads[_key(t)];
        if (hits != null && hits.isNotEmpty) {
          flush();
          cid = hits.length > 1 ? hits.removeAt(0) : hits.first;
          continue;
        }
        // 开头的横幅、末尾的宣传语都顶格且带网址；正文里提到文库的段落有缩进，不受影响
        if (t.toLowerCase().contains('wenku8.com')) continue;
      }
      if (cid == null || _separator.hasMatch(t)) continue;
      paragraphs.add(t);
    }
    flush();
    return texts;
  }

  /// 只比字：实体、大小写、空白、全角英文数字都不算差别
  static String _key(String s) => decodeEntities(s)
      .replaceAllMapped(RegExp('[０-９Ａ-Ｚａ-ｚ]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0))
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '');
}
