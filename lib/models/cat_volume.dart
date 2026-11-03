import 'package:ark_novel/models/cat_chapter.dart';

class CatVolume {
  final String title;
  final List<CatChapter> chapters;

  CatVolume({required this.title, required this.chapters});

  static CatVolume get empty => CatVolume(title: '', chapters: []);
}
