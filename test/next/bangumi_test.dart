import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/bangumi.dart';

List<({String name, String img})> bgm(List<String> names) => [for (final n in names) (name: n, img: 'img:$n')];

void main() {
  test('文库卷号：阿拉伯数字、中文数字；短篇、特典、8.5 卷不算', () {
    expect(wenkuVolumeNumber('第一卷'), 1);
    expect(wenkuVolumeNumber('第十卷 谋略的统治者'), 10);
    expect(wenkuVolumeNumber('第十一卷 矮人工匠'), 11);
    expect(wenkuVolumeNumber('第二十三卷'), 23);
    expect(wenkuVolumeNumber('第2卷'), 2);
    expect(wenkuVolumeNumber('第8.5卷 短篇集'), isNull);
    expect(wenkuVolumeNumber('BD特典'), isNull);
    expect(wenkuVolumeNumber('短篇'), isNull);
  });

  test('Bangumi 卷号：(N)、(8.5)、Ep.N，第一本没写号算 1', () {
    expect(bgmVolumeNumber('負けヒロインが多すぎる!', 0), 1);
    expect(bgmVolumeNumber('負けヒロインが多すぎる! (8.5)', 8), 8.5);
    expect(bgmVolumeNumber('86―エイティシックス―Ep.10 ―フラグメンタル・ネオテニー―', 9), 10);
    expect(bgmVolumeNumber('魔女の旅々(19)', 18), 19);
    expect(bgmVolumeNumber('“文学少女”と飢え渇く幽霊', 1), isNull);
  });

  test('按卷号对：特典、短篇不对；Bangumi 的 8.5 不会占掉第 9 卷', () {
    final m = matchVolumeCovers(
      ['第一卷', '第二卷', 'SSS短篇集', '第8.5卷', '第九卷'],
      bgm(['負け!', '負け! (2)', '負け! (8)', '負け! (8.5)', '負け! (9)']),
    );
    expect(m, {'第一卷': 'img:負け!', '第二卷': 'img:負け! (2)', '第九卷': 'img:負け! (9)'});
  });

  test('Bangumi 认不出卷号：正卷数一样才按顺序对，不一样一卷都不给', () {
    final names = ['“文学少女”と死にたがりの道化', '“文学少女”と飢え渇く幽霊', '“文学少女”と繋がれた愚者'];
    expect(matchVolumeCovers(['第一卷', '第二卷', '第三卷'], bgm(names)), {'第一卷': 'img:${names[0]}', '第二卷': 'img:${names[1]}', '第三卷': 'img:${names[2]}'});
    expect(matchVolumeCovers(['第一卷', '第二卷'], bgm(names)), isEmpty);
  });

  BgmSeries series(String name, List<String> vols, List<BgmExtra> extras) => (id: 1, name: name, vols: bgm(vols), extras: extras);
  BgmExtra single(String name, String cn) => (name: name, cn: cn, img: 'img:$name', vols: const []);
  BgmExtra sub(String name, String cn, List<String> vols) => (name: name, cn: cn, img: '', vols: bgm(vols));

  test('外传：英文词对外传系列再按卷号取；中文片段对单本；通用字眼、书名里的词不算', () {
    final sao = series('刀剑神域', ['ソードアート・オンライン (1) アインクラッド'], [
      sub('ソードアート・オンライン プログレッシブ', '刀剑神域: Progressive', ['SAOP (1)', 'SAOP (2)', 'SAOP (7)']),
      single('ソードアート・オンライン プログレッシブ 泡影のバルカローレ', '刀剑神域Progressive 泡影的船歌'),
      single('ソードアート・オンライン マテリアル (1) シュガーリィ・デイズ', ''),
    ]);
    expect(
      matchExtraCovers(['Progressive 1', 'Progressive 7 赤色焦热的狂想曲 上', 'Material 1 Sugary Days', 'BD特典小说 UW篇 IF线', '剧场版特典小说', '第一卷 艾恩葛朗特'], sao),
      {'Progressive 1': 'img:SAOP (1)', 'Progressive 7 赤色焦热的狂想曲 上': 'img:SAOP (7)'},
    );

    final eightySix = series('86―不存在的战区―', ['86―エイティシックス―'], [
      sub('86―エイティシックス― Alter', '', ['86―エイティシックス― Alter.1 ―死神ときどき青春―', '86―エイティシックス― Alter.2 ―魔法少女レジーナ☆レーナ―']),
    ]);
    expect(matchExtraCovers(['短篇集 Alter.2 ─魔法少女女王☆蕾娜─'], eightySix), {'短篇集 Alter.2 ─魔法少女女王☆蕾娜─': 'img:86―エイティシックス― Alter.2 ―魔法少女レジーナ☆レーナ―'});

    final overlord = series('OVERLORD', ['オーバーロード (1) 不死者の王'], [single('オーバーロード 亡国の吸血姫', 'OVERLORD 亡国的吸血姬'), single('オーバーロード 公式コミックアラカルト', 'OVER LORD 官方漫画同人集')]);
    expect(matchExtraCovers(['BD特典 外传 亡国的吸血姬', 'BD特典', '剧场版特典 卡兹平原的幽灵船'], overlord), {'BD特典 外传 亡国的吸血姬': 'img:オーバーロード 亡国の吸血姫'});
  });

  test('小数卷对主系列；SSS 这种单本按英文词对', () {
    final makeine = series('败犬女主太多了！', ['負け! ', '負け! (8)', '負け! (8.5)', '負け! (9)'], [single('負けヒロインが多すぎる! SSS', '')]);
    expect(matchExtraCovers(['第8.5卷', 'SSS短篇集', '第九卷'], makeine), {'第8.5卷': 'img:負け! (8.5)', 'SSS短篇集': 'img:負けヒロインが多すぎる! SSS'});
  });
}
