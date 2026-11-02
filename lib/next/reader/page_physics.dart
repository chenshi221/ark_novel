import 'package:flutter/widgets.dart';

/// 左右滑动翻页的手感：手指拖过一小段（[commitDistance]）松手就翻到下一页，只碰了一下就弹回原页；
/// 甩一下（速度够快）按甩的方向翻。
///
/// Flutter 自带的 PageScrollPhysics 要拖过半屏才翻页，平板上半屏很长，翻起来很沉。
/// 这里按"这次拖动是从哪一页开始的"（[origin]）算：一次最多翻一页，不会因为拖得远一下子翻过两页。
/// 用的时候 PageView 要关掉 pageSnapping，否则外面那层 PageScrollPhysics 会盖掉这里的判断。
class SwipePagePhysics extends ScrollPhysics {
  const SwipePagePhysics({required this.origin, super.parent});

  /// 这次拖动开始时在第几页（可以是小数：上一次翻页动画还没停稳时又按下）；null 时按离得最近的一页算
  final double? Function() origin;

  /// 拖过多远算"要翻页"：屏宽的 8%，限制在 24～56 像素之间
  static double commitDistance(double viewport) => (viewport * 0.08).clamp(24.0, 56.0);

  /// 松手时速度超过这个（像素 / 秒）就算甩，按方向翻页
  static const flingVelocity = 320.0;

  @override
  SwipePagePhysics applyTo(ScrollPhysics? ancestor) => SwipePagePhysics(origin: origin, parent: buildParent(ancestor));

  /// 松手后要停到的那一页
  static int targetPage({required double current, required double? from, required double velocity, required double viewport}) {
    final start = (from ?? current).roundToDouble();
    final moved = (current - start) * viewport;
    // 一次拖了超过一整页（极少见）：停在离得最近的一页
    if (moved.abs() >= viewport) return current.round();
    if (velocity.abs() >= flingVelocity) {
      // 甩的方向和拖的方向相反：手指往回带了一下，回到原页
      if (moved != 0 && moved.sign != velocity.sign) return start.toInt();
      return (start + velocity.sign).toInt();
    }
    if (moved.abs() >= commitDistance(viewport)) return (start + moved.sign).toInt();
    return start.toInt();
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    final viewport = position.viewportDimension;
    // 已经顶到头（第一页往前、最后一页往后）：交给外层的 Clamping 处理，翻章逻辑靠它发的 overscroll
    if (viewport <= 0 ||
        (velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = targetPage(current: position.pixels / viewport, from: origin(), velocity: velocity, viewport: viewport);
    final target = (page * viewport).clamp(position.minScrollExtent, position.maxScrollExtent);
    final tolerance = toleranceFor(position);
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity, tolerance: tolerance);
  }
}
