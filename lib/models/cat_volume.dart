import 'dart:convert';

import 'package:ark_novel/models/cat_chapter.dart';
import 'package:json_annotation/json_annotation.dart';

part 'cat_volume.g.dart';

@JsonSerializable(explicitToJson: true)
class CatVolume {
  final String title;
  final List<CatChapter> chapters;

  CatVolume({required this.title, required this.chapters});

  static CatVolume get empty => CatVolume(title: "", chapters: []);

  factory CatVolume.fromJson(Map<String, dynamic> json) => _$CatVolumeFromJson(json);

  Map<String, dynamic> toJson() => _$CatVolumeToJson(this);

  @override
  String toString() => jsonEncode(toJson());

  factory CatVolume.fromString(String json) => CatVolume.fromJson(jsonDecode(json));
}
