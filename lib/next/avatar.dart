import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 自己选的头像：只保存在本机（wenku8 的头像要在网站上改，这里不改网站上的）。
class _AvatarController extends Notifier<String?> {
  @override
  String? build() => Hive.box('session').get('avatar') as String?;

  Future<void> pick() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    final src = file?.path;
    if (src == null) return;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'avatar'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final dest = await File(src).copy(p.join(dir.path, 'avatar_${DateTime.now().millisecondsSinceEpoch}${p.extension(src)}'));
    await Hive.box('session').putAll({'avatar': dest.path, 'avatar:ts': DateTime.now().millisecondsSinceEpoch});
    state = dest.path;
  }

  Future<void> clear() async {
    await Hive.box('session').delete('avatar');
    await Hive.box('session').put('avatar:ts', DateTime.now().millisecondsSinceEpoch);
    state = null;
  }
}

final avatarProvider = NotifierProvider<_AvatarController, String?>(_AvatarController.new);
