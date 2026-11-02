import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../rules.dart';
import '../settings.dart';
import '../widgets.dart';
import 'page_curl.dart';
import 'page_physics.dart';
import 'paginator.dart';

/// 章节：正文（已套用替换规则、统一缩进）、插图地址、高亮位置。
class Chapter {
  const Chapter({required this.text, required this.images, required this.marks});

  final String text;
  final List<String> images;
  final List<Mark> marks;
}

/// 往前翻章时用的"落在最后一页"标记（偏移量超出任何正文）。
const kToEnd = 1 << 30;

typedef SpanOf = InlineSpan Function(int from, int to);

/// 阅读正文样式。分页测量和实际显示必须用**完全相同**的样式，所以把会被主题继承的属性都写死。
TextStyle readerStyle(ReaderPrefs prefs, Color color, {String? family, List<String>? fallback}) => TextStyle(
  fontSize: prefs.fontSize,
  height: prefs.lineHeight,
  color: color,
  fontFamily: family,
  fontFamilyFallback: fallback,
  fontWeight: FontWeight.w400,
  fontStyle: FontStyle.normal,
  letterSpacing: 0,
  wordSpacing: 0,
  decoration: TextDecoration.none,
  leadingDistribution: TextLeadingDistribution.proportional,
);

/// 正文每一行固定高度（字号 × 行距）：变色、高亮的字所在的行不会再比别的行高，切页和显示的行高才对得上。
StrutStyle readerStrut(TextStyle s) => StrutStyle.fromTextStyle(s, forceStrutHeight: true);

/// 键盘（和其他外部操作）驱动翻页 / 滚动：正文组件把自己的动作挂到这里。
class ReaderNav {
  VoidCallback? next;
  VoidCallback? prev;

  /// 滚动模式：按像素滚动；翻页模式不用
  void Function(double)? scrollBy;

  /// 翻页模式：当前第几屏（从 0 起）、共几屏，底部进度条用；滚动模式不用
  final page = ValueNotifier<(int, int)>((0, 0));

  /// 翻页模式跳到第几屏；滚动模式跳到本章的某个比例（0~1）
  void Function(int)? toPage;
  void Function(double)? toFraction;
}

/// 取出 [from, to) 这一段正文，高亮的地方染色（有备注的加虚线下划线），[hl] 是朗读正在读的那一句。颜色、底色和下划线不改变字形宽度，不影响分页。
InlineSpan buildSpan(Chapter c, int from, int to, TextStyle base, Set<String> noted, [(int, int)? hl, Color? hlColor]) {
  final cuts = <int>{from, to};
  for (final m in c.marks) {
    if (m.end <= from) continue;
    if (m.start >= to) break;
    cuts..add(math.max(m.start, from))..add(math.min(m.end, to));
  }
  if (hl != null) {
    for (final x in [hl.$1, hl.$2]) {
      if (x > from && x < to) cuts.add(x);
    }
  }
  final pts = cuts.toList()..sort();
  final children = <InlineSpan>[];
  var j = 0;
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], b = pts[i + 1];
    while (j < c.marks.length && c.marks[j].end <= a) {
      j++;
    }
    final m = j < c.marks.length && c.marks[j].start <= a ? c.marks[j] : null;
    final reading = hl != null && a >= hl.$1 && b <= hl.$2;
    TextStyle? style;
    if (m != null) {
      final color = Color(m.rule.color);
      style = m.rule.kind == RuleKind.color
          ? TextStyle(color: color)
          : TextStyle(color: color, backgroundColor: color.withValues(alpha: 0.13), decoration: noted.contains(m.rule.id) ? TextDecoration.underline : null, decorationStyle: TextDecorationStyle.dotted, decorationColor: color);
    }
    if (reading) style = (style ?? const TextStyle()).copyWith(backgroundColor: (hlColor ?? Colors.amber).withValues(alpha: 0.35));
    children.add(TextSpan(text: c.text.substring(a, b), style: style));
  }
  return TextSpan(style: base, children: children);
}

/// 每章开头的章节标题，高度固定成 [headingHeight] 算的值（分页按这个高度给第一页留位置）。
/// [accent]：标题染色，并在标题下面的留白里画一条装饰线（「晴空」背景的三角旗、角色主题的蜡笔线；不占额外高度，不影响分页）
Widget chapterHeading(String title, TextStyle body, double width, {(Color, Widget Function(double width))? accent}) {
  final text = Text(title, style: headingStyle(body).copyWith(color: accent?.$1), textScaler: TextScaler.noScaling);
  return SizedBox(
    height: headingHeight(title, body, width),
    child: Align(
      alignment: Alignment.topLeft,
      child: accent == null
          ? text
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [text, SizedBox(height: (body.fontSize ?? 18) * 0.35), accent.$2(math.min(width * 0.45, 160))],
            ),
    ),
  );
}

/// 点击检测：用原始指针事件，不进手势竞技场，所以不会被 [SelectionArea] 或翻页手势吞掉。
/// 按下后移动不到 14 像素、300 毫秒内抬起算一次点击；按下时已有选中文字则这次点击只用来取消选择。
class TapDetector extends StatefulWidget {
  const TapDetector({super.key, required this.child, required this.onTap, this.hasSelection});

  final Widget child;

  /// [local] 是点击在本组件内的位置，[size] 是组件大小，[global] 是屏幕位置
  final void Function(Offset local, Size size, Offset global) onTap;
  final bool Function()? hasSelection;

  @override
  State<TapDetector> createState() => _TapDetectorState();
}

class _TapDetectorState extends State<TapDetector> {
  Offset? _down;
  DateTime _at = DateTime.now();
  bool _ignore = false;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (e) {
      _down = e.position;
      _at = DateTime.now();
      _ignore = widget.hasSelection?.call() ?? false;
    },
    onPointerMove: (e) {
      if (_down != null && (e.position - _down!).distance > 14) _down = null;
    },
    onPointerCancel: (_) => _down = null,
    onPointerUp: (e) {
      final d = _down;
      _down = null;
      if (d == null || _ignore || DateTime.now().difference(_at) > const Duration(milliseconds: 300)) return;
      final box = context.findRenderObject() as RenderBox;
      widget.onTap(box.globalToLocal(e.position), box.size, e.position);
    },
    child: widget.child,
  );
}

enum TapAction { prev, next, menu }

/// 点击分区（Mihon 的几种方案）：[zone] 0 默认 1 L 型 2 Kindle 式 3 边缘式 4 只呼出菜单；
/// [invert] 0 不反转 1 水平 2 垂直 3 两者（反转 = 把点的位置镜像一下）。
/// 默认方案：翻页模式点左右两边翻页，滚动模式（[paged] 为 false）点哪里都呼出菜单，和以前一样。
TapAction tapActionAt(int zone, int invert, Offset local, Size size, {required bool paged}) {
  var x = (local.dx / size.width).clamp(0.0, 1.0);
  var y = (local.dy / size.height).clamp(0.0, 1.0);
  if (invert == 1 || invert == 3) x = 1 - x;
  if (invert == 2 || invert == 3) y = 1 - y;
  const a = 1 / 3, b = 2 / 3;
  switch (zone) {
    case 1: // 上和左中是上一页，下和右中是下一页
      if (y < a || (x < a && y < b)) return TapAction.prev;
      if (y >= b || x >= b) return TapAction.next;
      return TapAction.menu;
    case 2: // 上面一排呼出菜单，左边上一页，其余下一页
      if (y < a) return TapAction.menu;
      return x < a ? TapAction.prev : TapAction.next;
    case 3: // 左右两边下一页，底部中间上一页
      if (x < a || x >= b) return TapAction.next;
      return y >= b ? TapAction.prev : TapAction.menu;
    case 4:
      return TapAction.menu;
    default:
      if (!paged) return TapAction.menu;
      return x < 0.3 ? TapAction.prev : (x > 0.7 ? TapAction.next : TapAction.menu);
  }
}

/// 页脚：左边时间和电量（[status] 每分钟刷新，只重建这一行，不影响正文和分页），右边页码 / 进度。
class ReaderFooter extends StatelessWidget {
  const ReaderFooter({super.key, required this.right, required this.style, this.status});

  final String right;
  final TextStyle style;
  final ValueListenable<String>? status;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      status == null ? const SizedBox.shrink() : ValueListenableBuilder<String>(valueListenable: status!, builder: (_, v, _) => Text(v, style: style)),
      Text(right, style: style),
    ],
  );
}

/// 在 [key] 对应的段落里找屏幕位置 [global] 点中了哪个高亮，[base] 是这段文字在整章里的起点。
Mark? markAt(Chapter c, GlobalKey key, int base, Offset global) {
  final ro = key.currentContext?.findRenderObject();
  if (ro is! RenderParagraph) return null;
  final local = ro.globalToLocal(global);
  final pos = ro.getPositionForOffset(local).offset;
  // 只认真正落在那个字上的点击，行尾空白处不算
  final boxes = ro.getBoxesForSelection(TextSelection(baseOffset: pos, extentOffset: pos + 1));
  if (!boxes.any((b) => b.toRect().inflate(2).contains(local))) return null;
  final idx = base + pos;
  for (final m in c.marks) {
    if (idx >= m.start && idx < m.end) return m.rule.kind == RuleKind.highlight ? m : null;
  }
  return null;
}

/// 上下滚动。进度用字符偏移：保存时取视口顶部对应的字符，恢复时再换算回滚动位置，所以改字号、延迟加载插图都不会跳位置。
class ScrollBody extends StatefulWidget {
  const ScrollBody({
    super.key,
    required this.chapter,
    required this.spanOf,
    required this.style,
    required this.margin,
    this.title = '',
    this.headingAccent,
    required this.startOffset,
    required this.onOffset,
    required this.onEnd,
    required this.onNext,
    this.nextLabel = '下一章',
    required this.wrap,
    required this.onTapZone,
    this.menuOpen,
    required this.onMark,
    this.follow,
    this.nav,
    required this.hasSelection,
    this.tapZone = 0,
    this.tapInvert = 0,
    this.onPullDown,
    this.marked,
  });

  final int tapZone;
  final int tapInvert;

  /// 在章首继续往下拉：加 / 取消书签；[marked] 是当前位置有没有书签
  final VoidCallback? onPullDown;
  final bool Function()? marked;
  final Chapter chapter;
  final SpanOf spanOf;
  final TextStyle style;
  final double margin;

  /// 章节名，显示在正文开头
  final String title;
  final (Color, Widget Function(double width))? headingAccent;
  final int startOffset;
  final ValueChanged<int> onOffset;

  /// 滚到章末
  final VoidCallback onEnd;
  final VoidCallback? onNext;

  /// 章末按钮的字：全书最后一章是「读完了」
  final String nextLabel;
  final Widget Function(Widget) wrap;

  /// 点在空白处（切换菜单栏）
  final VoidCallback onTapZone;

  /// 菜单开着时点哪里都只收起菜单（[onTapZone]），不翻页、不点备注
  final bool Function()? menuOpen;
  final void Function(Mark) onMark;

  /// 朗读正在读的位置（字符偏移）：不在当前屏幕内时自动翻页 / 滚动过去
  final int? follow;
  final ReaderNav? nav;
  final bool Function() hasSelection;

  @override
  State<ScrollBody> createState() => _ScrollBodyState();
}

class _ScrollBodyState extends State<ScrollBody> {
  final _controller = ScrollController();
  final _textKey = GlobalKey();
  double _padTop = 0; // 正文第一行到滚动内容顶部的距离（含章节标题）

  @override
  void initState() {
    super.initState();
    widget.nav
      ?..next = (() => _page(1))
      ..prev = (() => _page(-1))
      ..scrollBy = _nudge
      ..toPage = null
      ..toFraction = ((f) {
        if (_controller.hasClients) _controller.jumpTo(f.clamp(0.0, 1.0) * _controller.position.maxScrollExtent);
      });
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void didUpdateWidget(ScrollBody old) {
    super.didUpdateWidget(old);
    final f = widget.follow;
    if (f == null || f == old.follow || !_controller.hasClients) return;
    final ro = _textKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final y = _padTop + ro.getOffsetForCaret(TextPosition(offset: math.min(f, widget.chapter.text.length)), Rect.zero).dy;
    final view = _controller.position;
    if (y < view.pixels || y > view.pixels + view.viewportDimension - 120) {
      _controller.animateTo((y - 80).clamp(0.0, view.maxScrollExtent), duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _nudge(double dy) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    _controller.animateTo((p.pixels + dy).clamp(0.0, p.maxScrollExtent), duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
  }

  /// 滚一屏（留一点重叠）；已经到底再往后就去下一章。
  void _page(int dir) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    if (dir > 0 && p.pixels >= p.maxScrollExtent - 2) return widget.onNext?.call();
    _nudge(dir * p.viewportDimension * 0.9);
  }

  void _restore() {
    if (!mounted || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    final off = widget.startOffset;
    final ro = _textKey.currentContext?.findRenderObject();
    if (off >= kToEnd) return _controller.jumpTo(max);
    if (off <= 0 || ro is! RenderParagraph) return;
    final caret = ro.getOffsetForCaret(TextPosition(offset: math.min(off, widget.chapter.text.length)), Rect.zero);
    _controller.jumpTo((_padTop + caret.dy).clamp(0.0, max));
  }

  int _charAtTop() {
    final ro = _textKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return 0;
    final top = (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero).dy;
    final y = top - ro.localToGlobal(Offset.zero).dy;
    return y <= 0 ? 0 : ro.getPositionForOffset(Offset(0, y)).offset;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chapter;
    final hasText = c.text.trim().isNotEmpty;
    final width = MediaQuery.sizeOf(context).width - widget.margin * 2;
    final head = hasText ? headingHeight(widget.title, widget.style, width) : 0.0;
    final padTop = MediaQuery.viewPaddingOf(context).top + 24;
    _padTop = padTop + head;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (n) {
        widget.onOffset(_charAtTop());
        if (n.metrics.maxScrollExtent <= 0 || n.metrics.pixels >= n.metrics.maxScrollExtent - 40) widget.onEnd();
        return false;
      },
      child: TapDetector(
        hasSelection: widget.hasSelection,
        onTap: (local, size, global) {
          if (widget.menuOpen?.call() ?? false) return widget.onTapZone();
          final m = markAt(c, _textKey, 0, global);
          if (m != null) return widget.onMark(m);
          switch (tapActionAt(widget.tapZone, widget.tapInvert, local, size, paged: false)) {
            case TapAction.prev:
              _page(-1);
            case TapAction.next:
              _page(1);
            case TapAction.menu:
              widget.onTapZone();
          }
        },
        child: PullBookmark(
          onPull: widget.onPullDown,
          marked: widget.marked,
          color: widget.style.color ?? Colors.grey,
          top: MediaQuery.viewPaddingOf(context).top,
          child: widget.wrap(
          SingleChildScrollView(
            controller: _controller,
            padding: EdgeInsets.fromLTRB(widget.margin, padTop, widget.margin, MediaQuery.viewPaddingOf(context).bottom + 48), // 底部留出页脚的高度，别挡字
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (head > 0) chapterHeading(widget.title, widget.style, width, accent: widget.headingAccent),
                Text.rich(widget.spanOf(0, c.text.length), key: _textKey, textScaler: TextScaler.noScaling, strutStyle: readerStrut(widget.style)),
                for (final url in c.images) Padding(padding: const EdgeInsets.only(top: 16), child: NetImage(url, fit: BoxFit.contain)),
                if (widget.onNext != null) Padding(padding: const EdgeInsets.only(top: 32), child: OutlinedButton(onPressed: widget.onNext, child: Text(widget.nextLabel))),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// 下拉加书签：往下拉时整页跟着手指往下移（越拉越沉），顶上露出一条，中间是书签图标和提示；
/// 拉过 [_threshold] 图标变实心、轻震一下，松手加 / 取消书签，页面带一点回弹缩回去。平时什么都不显示。
/// 翻页模式（[drag]）直接认竖向拖动；滚动模式只认滚到顶后继续往下拉（滚动视图的越界通知）。
class PullBookmark extends StatefulWidget {
  const PullBookmark({super.key, required this.child, required this.onPull, required this.marked, required this.color, required this.top, this.drag = false});

  final Widget child;
  final VoidCallback? onPull;
  final bool Function()? marked;
  final Color color;
  final double top; // 状态栏高度
  final bool drag;

  @override
  State<PullBookmark> createState() => _PullBookmarkState();
}

class _PullBookmarkState extends State<PullBookmark> with SingleTickerProviderStateMixin {
  static const _threshold = 72.0, _max = 120.0;
  double _pull = 0; // 手指拉下的距离（原始值）
  late final _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 380))..addListener(() => setState(() {}));
  double _from = 0; // 松手时露出的高度，回弹从这里开始

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  /// 页面实际下移的距离：越往下越拉不动
  double get _shown {
    if (_back.isAnimating) return _from * (1 - Curves.easeOutBack.transform(_back.value));
    return _pull <= 0 ? 0 : _max * (1 - math.exp(-_pull / _max));
  }

  void _update(double v) {
    if (_back.isAnimating) _back.stop();
    final was = _pull >= _threshold;
    setState(() => _pull = v.clamp(0, _max * 3));
    if (!was && _pull >= _threshold) HapticFeedback.mediumImpact();
  }

  void _release() {
    if (_pull <= 0) return;
    if (_pull >= _threshold) widget.onPull?.call();
    _from = _shown;
    _pull = 0;
    _back.forward(from: 0);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      _update(_pull - n.overscroll);
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      // iOS 回弹式滚动：顶部越界是负的 pixels；正常往下滚就收回
      n.metrics.pixels < 0 ? _update(-n.metrics.pixels) : (_pull > 0 ? _update(_pull - (n.scrollDelta ?? 0)) : null);
    } else if (n is ScrollEndNotification) {
      _release();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onPull == null) return widget.child;
    final shown = _shown;
    final ready = _pull >= _threshold;
    final marked = widget.marked?.call() ?? false;
    final accent = Theme.of(context).colorScheme.primary;
    final progress = (_pull / _threshold).clamp(0.0, 1.0);
    Widget child = Transform.translate(offset: Offset(0, shown), child: widget.child);
    child = widget.drag
        ? GestureDetector(
            onVerticalDragUpdate: (d) => _update(_pull + d.delta.dy),
            onVerticalDragEnd: (_) => _release(),
            onVerticalDragCancel: _release,
            child: child,
          )
        : NotificationListener<ScrollNotification>(onNotification: _onScroll, child: child);
    return Stack(
      children: [
        child,
        // 页面下移后露出来的那一条（画在页面上面：仿真翻页的页面不透明）
        if (shown > 1)
          Positioned(
            top: widget.top,
            left: 0,
            right: 0,
            height: math.max(0, shown),
            child: IgnorePointer(
              child: Opacity(
                opacity: (shown / 48).clamp(0.0, 1.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Transform.scale(
                      scale: 0.8 + 0.25 * progress,
                      child: Icon(
                        ready ? (marked ? Icons.bookmark_remove : Icons.bookmark_added) : (marked ? Icons.bookmark : Icons.bookmark_add_outlined),
                        size: 26,
                        color: ready ? accent : widget.color.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      ready ? (marked ? '松手取消书签' : '松手添加书签') : (marked ? '下拉取消书签' : '下拉添加书签'),
                      style: TextStyle(fontSize: 13, color: ready ? accent : widget.color.withValues(alpha: 0.55), fontWeight: ready ? FontWeight.w600 : null),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 左右翻页（滑动 / 仿真）。页面大小或字号、字体变了会重新分页，并按"当前读到的字符"回到同一处。
class PagedBody extends StatefulWidget {
  const PagedBody({
    super.key,
    required this.chapter,
    required this.spanOf,
    required this.style,
    required this.margin,
    required this.title,
    required this.curl,
    this.cover = false,
    this.dual = false,
    required this.background,
    required this.color,
    required this.startOffset,
    required this.onOffset,
    required this.onEnd,
    required this.onPrev,
    required this.onNext,
    required this.wrap,
    required this.onTapZone,
    this.menuOpen,
    required this.onMark,
    this.follow,
    this.nav,
    required this.hasSelection,
    this.status,
    this.tapZone = 0,
    this.tapInvert = 0,
    this.showFooter = true,
    this.animate = true,
    this.volumeProgress,
    this.onPullDown,
    this.marked,
    this.headingAccent,
  });

  /// 在页面上往下拉：加 / 取消书签；[marked] 是当前页有没有书签
  final VoidCallback? onPullDown;
  final bool Function()? marked;
  final (Color, Widget Function(double width))? headingAccent;

  /// 最近一次排版用的单页大小和一屏几页：书签算页码时用，和正文排版一模一样
  static (Size, int)? lastLayout;

  /// 滑动翻页时要不要动画
  final bool animate;

  /// 本章读到的比例（0~1）换算成本卷进度，页脚右边的百分比用它；没有时显示本章进度
  final double Function(double)? volumeProgress;

  final int tapZone;
  final int tapInvert;
  final bool showFooter;

  final Chapter chapter;
  final SpanOf spanOf;
  final TextStyle style;
  final double margin;
  final String title;

  /// 页脚左边的"时间 电量"
  final ValueListenable<String>? status;
  final bool curl;
  final bool cover;

  /// 宽屏双页：一屏显示左右两页，像摊开的书
  final bool dual;
  final Color background;
  final Color color;
  final int startOffset;
  final ValueChanged<int> onOffset;
  final VoidCallback onEnd;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final Widget Function(Widget) wrap;
  final VoidCallback onTapZone;

  /// 菜单开着时点哪里都只收起菜单（[onTapZone]），不翻页、不点备注
  final bool Function()? menuOpen;
  final void Function(Mark) onMark;

  /// 朗读正在读的位置（字符偏移）：不在当前屏幕内时自动翻页 / 滚动过去
  final int? follow;
  final ReaderNav? nav;
  final bool Function() hasSelection;

  @override
  State<PagedBody> createState() => _PagedBodyState();
}

class _PagedBodyState extends State<PagedBody> {
  final _curl = PageCurlController();
  final _keys = <int, GlobalKey>{};
  PageController? _controller;
  List<int> _starts = const [0];
  Object? _sig;
  int _page = 0;
  int _cur = 0; // 当前读到的字符偏移，重新分页时按它定位
  double _overscroll = 0;
  double? _dragFrom; // 这次拖动开始时在第几页，翻页手感按它算（见 SwipePagePhysics）
  int _cols = 1; // 一屏几页（1 或 2）；_page、翻页动画的"页"都以一屏为单位
  double _head = 0; // 第一页开头章节标题的高度
  double _width = 0;
  Size _imgBox = Size.zero; // 插图页的大小（整页，双页时一半），按它提前解码
  Chapter? _fetched; // 已经开始在后台下载整章插图的那一章

  @override
  void initState() {
    super.initState();
    _cur = widget.startOffset;
    widget.nav
      ?..next = (() => _step(1))
      ..prev = (() => _step(-1))
      ..toFraction = null
      ..toPage = _jump;
  }

  @override
  void didUpdateWidget(PagedBody old) {
    super.didUpdateWidget(old);
    final f = widget.follow;
    if (f == null || f == old.follow || _total == 0) return;
    final p = _pageOf(f);
    if (p == _page) return;
    if (widget.curl) {
      _curl.goTo(p);
    } else {
      _controller?.animateToPage(p, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Chapter get _c => widget.chapter;

  bool get _hasText => _c.text.trim().isNotEmpty;

  int get _textPages => _hasText ? _starts.length : 0;

  /// 单页总数
  int get _total => _textPages + _c.images.length;

  /// 翻页的单位数（双页时两页算一屏）
  int get _units => (_total + _cols - 1) ~/ _cols;

  int _offsetOfPage(int page) => page < _textPages ? _starts[page] : _c.text.length + 1 + (page - _textPages);

  int _offsetOf(int unit) => _offsetOfPage(unit * _cols);

  /// 字符偏移所在的那一屏。
  int _pageOf(int offset) {
    if (_total == 0) return 0;
    final int page;
    if (offset >= kToEnd) {
      page = _total - 1;
    } else if (offset > _c.text.length) {
      page = math.min(_textPages + (offset - _c.text.length - 1), _total - 1);
    } else {
      page = _hasText ? pageOfOffset(_starts, offset) : 0;
    }
    return page ~/ _cols;
  }

  GlobalKey _keyFor(int page) => _keys.putIfAbsent(page, GlobalKey.new);

  /// 底部进度条拖到第几屏
  void _jump(int unit) {
    final p = unit.clamp(0, math.max(_units - 1, 0)).toInt();
    if (widget.curl) {
      _curl.goTo(p);
    } else {
      _controller?.jumpToPage(p);
    }
  }

  void _publish() {
    final nav = widget.nav;
    if (nav == null) return;
    // 在 build 里分页后也要更新，推迟到这一帧画完，免得在 build 期间通知别的组件
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) nav.page.value = (_page, _units);
    });
  }

  void _changed(int page) {
    _page = page;
    _publish();
    _cur = _offsetOf(page);
    widget.onOffset(_cur);
    if (page >= _units - 1) widget.onEnd();
    _prefetch();
  }

  /// 插图章：整章的图按顺序在后台下好；前后一屏的图提前解码，翻过去直接出图（翻页时下一页才建出来）
  void _prefetch() {
    if (_c.images.isEmpty || _imgBox.isEmpty) return;
    if (!identical(_fetched, _c)) {
      _fetched = _c;
      for (final url in _c.images) {
        NetImage.precache(context, url, _imgBox, decode: false);
      }
    }
    for (var i = (_page - 1) * _cols; i < (_page + 2) * _cols; i++) {
      if (i >= _textPages && i < _total) NetImage.precache(context, _c.images[i - _textPages], _imgBox, fit: BoxFit.contain);
    }
  }

  Widget _pageContent(BuildContext context, int unit, bool live, EdgeInsets pad) {
    if (_cols == 1) return _single(context, unit, live, pad);
    final line = widget.color.withValues(alpha: 0.12);
    return Row(
      children: [
        for (var k = 0; k < _cols; k++) ...[
          Expanded(child: unit * _cols + k < _total ? _single(context, unit * _cols + k, live, pad) : const SizedBox.shrink()),
          if (k < _cols - 1) VerticalDivider(width: 1, thickness: 1, indent: 24, endIndent: 24, color: line),
        ],
      ],
    );
  }

  Widget _single(BuildContext context, int i, bool live, EdgeInsets pad) {
    if (i >= _textPages) return Center(child: NetImage(_c.images[i - _textPages], fit: BoxFit.contain));
    final end = i + 1 < _starts.length ? _starts[i + 1] : _c.text.length;
    final faint = TextStyle(fontSize: 11, color: widget.color.withValues(alpha: 0.5));
    final view = MediaQuery.viewPaddingOf(context);
    return Stack(
      children: [
        // 页尾的换行会多出一个空行超出页面，所以不用 Column：标题单独放，正文往下让出标题的高度
        if (i == 0 && _head > 0) Positioned(top: pad.top, left: pad.left, right: pad.right, child: chapterHeading(widget.title, widget.style, _width, accent: widget.headingAccent)),
        Padding(
          padding: i == 0 ? pad.copyWith(top: pad.top + _head) : pad,
          child: Text.rich(widget.spanOf(_starts[i], end), key: live ? _keyFor(i) : null, textScaler: TextScaler.noScaling, strutStyle: readerStrut(widget.style)),
        ),
        if (i > 0 || _head == 0) Positioned(top: view.top + 10, left: widget.margin, right: widget.margin, child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: faint)),
        if (widget.showFooter) Positioned(bottom: view.bottom + 10, left: widget.margin, right: widget.margin, child: ReaderFooter(status: widget.status, right: '${i + 1}/$_total · ${((widget.volumeProgress?.call((i + 1) / _total) ?? (i + 1) / _total) * 100).floor()}%', style: faint)),
      ],
    );
  }

  void _tap(Offset local, Size size, Offset global) {
    if (widget.menuOpen?.call() ?? false) return widget.onTapZone();
    for (var k = 0; k < _cols; k++) {
      final p = _page * _cols + k;
      final m = p < _textPages ? markAt(_c, _keyFor(p), _starts[p], global) : null;
      if (m != null) return widget.onMark(m);
    }
    switch (tapActionAt(widget.tapZone, widget.tapInvert, local, size, paged: true)) {
      case TapAction.prev:
        _step(-1);
      case TapAction.next:
        _step(1);
      case TapAction.menu:
        widget.onTapZone();
    }
  }

  void _step(int delta) => widget.curl ? (delta > 0 ? _curl.next() : _curl.prev()) : _slide(delta);

  void _slide(int delta) {
    final target = _page + delta;
    if (target < 0) return widget.onPrev?.call();
    if (target >= _units) return widget.onNext?.call();
    if (widget.animate) {
      _controller?.animateToPage(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    } else {
      _controller?.jumpToPage(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = MediaQuery.viewPaddingOf(context);
    final pad = EdgeInsets.fromLTRB(widget.margin, view.top + 36, widget.margin, view.bottom + 36);
    return LayoutBuilder(
      builder: (context, box) {
        final cols = widget.dual && box.maxWidth >= 900 ? 2 : 1;
        final size = Size(box.maxWidth / cols - pad.horizontal, box.maxHeight - pad.vertical);
        PagedBody.lastLayout = (size, cols);
        // 同样的版面（大小、样式、正文）不重复分页；开关菜单栏、拖滑块这类重建不会触发全文排版
        final sig = Object.hash(size, cols, widget.style, _c.text.length, _c.text.hashCode, widget.title);
        if (sig != _sig) {
          final keep = _sig == null ? widget.startOffset : _cur;
          _sig = sig;
          _cols = cols;
          _width = size.width;
          _head = _hasText ? headingHeight(widget.title, widget.style, size.width) : 0;
          _starts = _hasText ? paginate(_c.text, widget.style, size, strut: readerStrut(widget.style), firstTop: _head) : const [0];
          _controller?.dispose();
          _controller = null;
          _page = _pageOf(keep);
          _cur = _offsetOf(_page);
          _keys.clear();
          _publish();
          _imgBox = Size(box.maxWidth / cols, box.maxHeight);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _prefetch();
          });
        }
        final Widget pages;
        if (widget.curl) {
          pages = PageCurl(
            key: ValueKey(sig),
            controller: _curl,
            cover: widget.cover,
            pageCount: _units,
            initialIndex: _page,
            background: widget.background,
            pageBuilder: (context, i, live) => _pageContent(context, i, live, pad),
            onIndexChanged: _changed,
            onReachStart: widget.onPrev,
            onReachEnd: widget.onNext,
          );
        } else {
          _controller ??= PageController(initialPage: _page);
          pages = NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification) _dragFrom = n.dragDetails == null ? null : _controller?.page;
              // 第一页往前滑、最后一页往后滑：松手后切到上一章 / 下一章
              if (n is OverscrollNotification) _overscroll = n.overscroll;
              if (n is ScrollEndNotification) {
                _dragFrom = null;
                if (_overscroll > 0) widget.onNext?.call();
                if (_overscroll < 0) widget.onPrev?.call();
                _overscroll = 0;
              }
              return false;
            },
            child: PageView.builder(
              key: ValueKey(sig),
              controller: _controller,
              // 拖一小段就翻页（不用拖过半屏）；对齐到整页由 SwipePagePhysics 自己做，所以关掉 pageSnapping
              pageSnapping: false,
              physics: SwipePagePhysics(origin: () => _dragFrom, parent: const ClampingScrollPhysics()),
              itemCount: _units,
              onPageChanged: _changed,
              itemBuilder: (context, i) => _pageContent(context, i, true, pad),
            ),
          );
        }
        return TapDetector(
          hasSelection: widget.hasSelection,
          onTap: _tap,
          child: PullBookmark(onPull: widget.onPullDown, marked: widget.marked, drag: true, color: widget.color, top: view.top, child: widget.wrap(pages)),
        );
      },
    );
  }
}
