import 'dart:convert';

import 'package:dio/dio.dart';

import '../../common/image_url_helper.dart';
import '../../models/cat_chapter.dart';
import '../../models/cat_volume.dart';
import '../../models/content.dart';

/// 调用文库 Android App 接口失败：所有端点都不可用、返回的是 HTML 错误页、目录/正文为空等。
class Wenku8AppApiException implements Exception {
  const Wenku8AppApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 文库 Android App 接口客户端。
///
/// 网站对版权受限的小说不再提供正文（只剩一句「因版权问题…」），但官方 App 接口
/// 仍然会返回这些内容。这里按 Greasyfork「轻小说文库+」脚本逆向出的协议直接请求：
/// `POST android.php`，请求体见 [requestBody]，目录/正文通过 base64 编码的 action 区分。
///
/// 接口本身随时可能失效（返回 Welcome / Bad request. / Cloudflare 页面），因此按构造参数 endpoints
/// 的顺序逐个回退；全部端点失败时抛 [Wenku8AppApiException]，由界面按「接口不可用」处理。
class Wenku8AppApi {
  Wenku8AppApi({Dio? dio, List<String> endpoints = defaultEndpoints}) : _dio = dio ?? Dio(), _endpoints = List<String>.unmodifiable(endpoints) {
    _dio.options = _dio.options.copyWith(
      responseType: ResponseType.bytes,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
    );
  }

  /// 端点顺序：社区中继优先（官方接口经常被 Cloudflare 拦成 HTML），失败再回退官方接口。
  static const List<String> defaultEndpoints = ['https://wenku8-relay.mewx.org/android.php', 'http://app.wenku8.com/android.php'];

  /// App 版本号，接口只认这个值。
  static const String appVer = '1.13';

  /// 接口只认官方 App 的 UA，换成浏览器的 UA 会直接被拒绝。
  static const String _userAgent = 'Dalvik/2.1.0 (Linux; U; Android 7.1.2; unknown Build/NZH54D)';

  static final RegExp _imagePattern = RegExp(r'<!--image-->(.*?)<!--image-->', dotAll: true);

  /// 分隔行（★☆◆◇ 之类只由装饰符号组成的行）的判定，见 [chapter]。
  /// 省略号、问叹号、引号都不算，「……」「！？」这类台词要留着。
  static final RegExp _separatorPattern = RegExp(r'^[\s★☆◆◇■□▲△▼▽○●◎※＊*\-—–_=＝~～·・]+$');
  static final RegExp _volumePattern = RegExp(r'<volume\b([^>]*)>(.*?)</volume>', caseSensitive: false, dotAll: true);
  static final RegExp _chapterPattern = RegExp(r'<chapter\b([^>]*)>(.*?)</chapter>', caseSensitive: false, dotAll: true);
  static final RegExp _entityPattern = RegExp(r'&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);');

  final Dio _dio;
  final List<String> _endpoints;

  /// 构造接口要求的表单体：`&appver=...&request=<base64(action)>&timetoken=<毫秒>`。
  ///
  /// action 是纯 ASCII（如 `action=book&do=text&aid=1&cid=2&t=0`），它的 base64 里不会出现
  /// `+`/`/`，所以直接拼进表单也不会被服务端按 URL 编码规则解码坏；`timetoken` 用于防重放。
  static String requestBody(String actionQuery) {
    return '&appver=$appVer&request=${base64Encode(utf8.encode(actionQuery))}&timetoken=${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 取一章正文。
  ///
  /// App 接口返回纯文本（UTF-8，`\r\n` 分行），插图用 `<!--image-->URL<!--image-->` 标记。
  /// 这里按行 trim、去空行，过滤分隔行、去掉末尾的页脚行，图片单独返回、不混进正文；
  /// 正文和图片都没有时抛 [Wenku8AppApiException]（多半是接口失效返回了空内容）。
  Future<Content> chapter(String aid, String cid) async {
    final text = await _request('action=book&do=text&aid=$aid&cid=$cid&t=0', accept: (value) => value.trim().isNotEmpty);

    final images = <String>[];
    final withoutImages = text.replaceAllMapped(_imagePattern, (match) {
      final url = ImageUrlHelper.normalize(match.group(1) ?? '');
      if (url.isNotEmpty) images.add(url);
      return '';
    });

    final paragraphs = <String>[];
    for (final line in withoutImages.split(RegExp(r'\r\n|\r|\n'))) {
      final value = line.trim();
      if (value.isEmpty || _isSeparatorLine(value)) continue;
      paragraphs.add(value);
    }
    // 宣传语只在末尾，正文中间提到文库的段落不动
    while (paragraphs.isNotEmpty && _isFooterLine(paragraphs.last)) {
      paragraphs.removeLast();
    }

    final body = paragraphs.join('\n');
    if (body.isEmpty && images.isEmpty) {
      throw Wenku8AppApiException('正文接口没有返回内容（aid=$aid, cid=$cid）');
    }
    return Content(text: body, images: images);
  }

  /// 取整本书的目录。
  ///
  /// 接口返回 XML（可能带 CDATA）：`<volume vid="12">卷名<chapter cid="123">章节名</chapter>…</volume>`，
  /// 按卷分组后返回；目录为空时抛 [Wenku8AppApiException]。
  Future<List<CatVolume>> catalogue(String aid) async {
    final xml = await _request(
      'action=book&do=list&aid=$aid&t=0',
      accept: (value) => value.toLowerCase().contains('<volume') || value.toLowerCase().contains('<chapter'),
    );
    final volumes = _parseCatalogue(xml);
    if (volumes.isEmpty) throw Wenku8AppApiException('目录接口没有返回任何章节（aid=$aid）');
    return volumes;
  }

  /// 按构造参数 endpoints 的顺序请求，返回第一个通过 [accept] 校验的响应；全部失败时汇总每个端点的原因后抛错。
  Future<String> _request(String action, {bool Function(String text)? accept}) async {
    final failures = <String>[];
    for (final endpoint in _endpoints) {
      try {
        final text = await _post(endpoint, action);
        if (_isFailureResponse(text)) {
          failures.add('$endpoint: 返回了错误页');
          continue;
        }
        if (accept != null && !accept(text)) {
          failures.add('$endpoint: 返回内容格式不对');
          continue;
        }
        return text;
      } on DioException catch (e) {
        failures.add('$endpoint: ${_describeDioException(e)}');
      } catch (e) {
        failures.add('$endpoint: $e');
      }
    }
    throw Wenku8AppApiException('文库 App 接口不可用（${failures.length} 个端点都失败了）：${failures.join('；')}');
  }

  /// POST 一个 action，并把响应体按 UTF-8 解码（容错，避免个别坏字节让整章失败）。
  Future<String> _post(String endpoint, String action) async {
    final response = await _dio.post<dynamic>(
      endpoint,
      data: requestBody(action),
      options: Options(contentType: Headers.formUrlEncodedContentType, headers: {'User-Agent': _userAgent, 'Accept': '*/*'}),
    );

    final data = response.data;
    final List<int> bytes;
    if (data is List<int>) {
      bytes = data;
    } else if (data is String) {
      bytes = utf8.encode(data);
    } else {
      bytes = data == null ? const [] : utf8.encode('$data');
    }

    final text = utf8.decode(bytes, allowMalformed: true);
    // 有些节点会在前面带 BOM，去掉后方便按首字符判断是不是 HTML
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }

  /// 接口失效时返回的是 HTML（Welcome / Bad request. / Cloudflare 拦截页），不是我们要的数据。
  static bool _isFailureResponse(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.isEmpty) return true;

    final head = trimmed.length > 600 ? trimmed.substring(0, 600) : trimmed;
    final lower = head.toLowerCase();
    if (lower.startsWith('<!doctype') || lower.contains('<html')) return true;
    if (lower.contains('bad request') || lower.contains('cloudflare')) return true;

    // 失效时也可能只回一句 Welcome，正常数据的首行不会这么短
    if (trimmed.length <= 200 && lower.startsWith('welcome')) return true;
    return false;
  }

  /// 只由符号组成的分隔行（例如 `◆◇◆◇`、`★☆★☆`），正文里没有意义。
  static bool _isSeparatorLine(String line) => _separatorPattern.hasMatch(line);

  /// 页脚行：App 接口的正文末尾会带上文库的宣传语。
  static bool _isFooterLine(String line) {
    final lower = line.toLowerCase();
    return lower.contains('wenku8.com') || lower.contains('wenku8.net') || lower.contains('本文来自');
  }

  /// 解析目录 XML。卷名、章节名可能是 CDATA，也可能是普通文本（带 XML 实体），两种都要解。
  static List<CatVolume> _parseCatalogue(String xml) {
    final volumes = <CatVolume>[];
    for (final volume in _volumePattern.allMatches(xml)) {
      final inner = volume.group(2) ?? '';
      final chapters = _parseChapters(inner);
      final title = _xmlText(inner.replaceAll(_chapterPattern, ''));
      if (title.isEmpty && chapters.isEmpty) continue;
      volumes.add(CatVolume(title: title.isEmpty ? '正文' : title, chapters: chapters));
    }

    if (volumes.isEmpty) {
      // 个别接口版本不套 <volume>，直接平铺章节
      final chapters = _parseChapters(xml);
      if (chapters.isNotEmpty) volumes.add(CatVolume(title: '正文', chapters: chapters));
    }
    return volumes;
  }

  static List<CatChapter> _parseChapters(String xml) {
    final chapters = <CatChapter>[];
    for (final chapter in _chapterPattern.allMatches(xml)) {
      final cid = _attribute(chapter.group(1) ?? '', 'cid');
      if (cid.isEmpty) continue;
      final title = _xmlText(chapter.group(2) ?? '');
      chapters.add(CatChapter(title: title.isEmpty ? '无题' : title, cid: cid));
    }
    return chapters;
  }

  /// 读标签属性，值里的 XML 实体也一并解开（例如作者名里的 `&amp;`）。
  static String _attribute(String source, String name) {
    final pattern = RegExp('(?:^|\\s)${RegExp.escape(name)}\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')', caseSensitive: false);
    final match = pattern.firstMatch(source);
    if (match == null) return '';
    return _xmlText(match.group(1) ?? match.group(2) ?? '');
  }

  /// 解 CDATA 包裹与 XML 实体，再 trim。
  static String _xmlText(String raw) => _decodeXml(raw.replaceAll('<![CDATA[', '').replaceAll(']]>', '')).trim();

  static String _decodeXml(String value) {
    return value.replaceAllMapped(_entityPattern, (match) {
      final entity = match.group(1)!;
      if (entity.startsWith('#')) {
        final isHex = entity.length > 1 && (entity[1] == 'x' || entity[1] == 'X');
        final code = isHex ? int.tryParse(entity.substring(2), radix: 16) : int.tryParse(entity.substring(1));
        return code == null || code < 0 || code > 0x10FFFF ? match.group(0)! : String.fromCharCode(code);
      }
      return switch (entity) {
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        'nbsp' => ' ',
        _ => match.group(0)!,
      };
    });
  }

  static String _describeDioException(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) return 'HTTP $status';
    return switch (error.type) {
      DioExceptionType.connectionTimeout => '连接超时',
      DioExceptionType.sendTimeout => '发送超时',
      DioExceptionType.receiveTimeout => '接收超时',
      DioExceptionType.transformTimeout => '处理超时',
      DioExceptionType.badCertificate => '证书错误',
      DioExceptionType.badResponse => '响应异常',
      DioExceptionType.cancel => '请求已取消',
      DioExceptionType.connectionError => '网络连接失败',
      _ => '网络错误',
    };
  }
}
