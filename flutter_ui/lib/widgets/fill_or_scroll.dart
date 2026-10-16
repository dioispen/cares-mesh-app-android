import 'package:flutter/material.dart';

/// 內容放得下時撐滿可用高度（原本的置中、`Spacer` 照常作用），放不下時改成可以捲動（#79）。
///
/// 小螢幕、放大字體、鍵盤彈出或平板橫向時，固定排版的 `Column` 會超出畫面；包一層這個，
/// 空間夠時看起來和原本一樣，不夠時才捲動。
///
/// [child] 裡有 `Spacer`／`Expanded` 時要設 [fillWithFlex]：會多包一層 `IntrinsicHeight`，
/// 讓 flex 子元件在可捲動的區域裡也有固定高度可以分配。這時 [child] 裡不能有 `LayoutBuilder`
/// 等不支援 intrinsic 尺寸的 widget。
class FillOrScroll extends StatelessWidget {
  const FillOrScroll({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.fillWithFlex = false,
  });

  final Widget child;

  /// 捲動區域內、內容外圍的留白。
  final EdgeInsets padding;
  final bool fillWithFlex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 寬度也撐滿：Scaffold 給 body 的是寬鬆的限制，不撐滿的話內容會縮到左上角。
        double fill(double max, double inset) =>
            max.isFinite ? (max - inset).clamp(0.0, double.infinity) : 0.0;
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: fill(constraints.maxWidth, padding.horizontal),
              minHeight: fill(constraints.maxHeight, padding.vertical),
            ),
            child: fillWithFlex ? IntrinsicHeight(child: child) : child,
          ),
        );
      },
    );
  }
}
