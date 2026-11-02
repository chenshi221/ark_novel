import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'theme.dart';

/// 阅读器字体：系统默认 / 衬线 / 自己选的字体文件（ttf、otf）。
/// 选的文件复制到应用目录，每次选择换一个新的字体名，避免旧字体被缓存。
class FontStore {
  FontStore._();

  static Box get _box => Hive.box('session');

  static String? get customFamily => _box.get('font:family') as String?;

  /// 启动时把上次选的字体文件重新加载进引擎。
  /// 不挡着启动（字体文件可能有十几 MB），在后台加载；阅读页用自选字体时等 [ready] 变成 true 再排版。
  static Future<void> loadSaved() async {
    try {
      final path = _box.get('font:path') as String?;
      final family = customFamily;
      if (path == null || family == null) return;
      final file = File(path);
      if (await file.exists()) await _load(family, await file.readAsBytes());
    } catch (_) {
      // 字体文件坏了就按系统字体显示
    } finally {
      ready.value = true;
    }
  }

  /// 上次选的字体加载完了（或者没有要加载的）
  static final ready = ValueNotifier<bool>(false);

  static Future<void> _load(String family, Uint8List bytes) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  /// 弹出文件选择器并加载；用户取消返回 false。
  static Future<bool> pick() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    final src = file?.path;
    if (src == null) return false;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'font'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = await File(src).copy(p.join(dir.path, 'font_$stamp${p.extension(src)}'));
    final family = 'ReaderFont$stamp';
    await _load(family, await dest.readAsBytes());
    await _box.put('font:path', dest.path);
    await _box.put('font:family', family);
    return true;
  }

  /// 字体选项：编号 → 显示名。0 系统默认 1 系统衬线 2 自选文件 3 霞鹜文楷 4 思源宋体。
  static const names = {0: '系统默认', 1: '系统衬线', 3: '霞鹜文楷', 4: '思源宋体', 2: '自选字体'};

  /// 没有自选字体时按系统默认。内置字体只含常用字，缺的字回退到系统字体。
  static ({String? family, List<String>? fallback}) resolve(int font) => switch (font) {
    1 => (family: null, fallback: kSerifFallback),
    2 when customFamily != null => (family: customFamily, fallback: null),
    3 => (family: 'LXGWWenKai', fallback: kSerifFallback),
    4 => (family: 'NotoSerifSCBundled', fallback: kSerifFallback),
    _ => (family: null, fallback: null),
  };
}
