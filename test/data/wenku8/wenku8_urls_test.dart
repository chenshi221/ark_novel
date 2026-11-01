import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/common/charset_type.dart';

void main() {
  const base = 'https://www.wenku8.net';
  const gbk = Wenku8Urls(base, CharsetType.gbk);
  const big5 = Wenku8Urls(base, CharsetType.big5Hkscs);

  test('普通页面地址', () {
    expect(gbk.novelDetail('1973'), '$base/modules/article/articleinfo.php?id=1973');
    expect(gbk.chapterContent('1973', '69000'), '$base/modules/article/reader.php?aid=1973&cid=69000');
    expect(gbk.bookshelf(2), '$base/modules/article/bookcase.php?classid=2');
    expect(gbk.userInfo(), '$base/userdetail.php');
  });

  test('分类和搜索词按页面编码做百分号编码', () {
    expect(gbk.category('魔法', '0', 1), '$base/modules/article/tags.php?t=%C4%A7%B7%A8&v=0&page=1');
    expect(gbk.searchByTitle('中', 2), '$base/modules/article/search.php?searchtype=articlename&searchkey=%D6%D0&page=2');
    expect(big5.searchByAuthor('中', 1), '$base/modules/article/search.php?searchtype=author&searchkey=%A4%A4&page=1');
  });

  test('发表按钮的值随编码变化', () {
    expect(gbk.submitButtonValue(), '+%B7%A2%B1%ED%CA%E9%C6%C0+');
    expect(big5.submitButtonValue(), '+%B5%6F%AA%ED%AE%D1%B5%FB+');
  });

  test('账号密码登录表单：用户名按页面编码，有效期默认很长', () {
    expect(gbk.loginSubmit(), '$base/login.php?do=submit');
    expect(gbk.loginForm('中a', 'p&ss'), 'username=%D6%D0%61&password=p%26ss&usecookie=315360000&action=login');
  });
}
