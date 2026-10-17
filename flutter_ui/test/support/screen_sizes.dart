import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一種要檢查排版的螢幕（#79）：邏輯尺寸、系統字體倍率，以及鍵盤高度（0 是沒開鍵盤）。
class ScreenCase {
  const ScreenCase(this.name, this.size, {this.textScale = 1.0, this.keyboard = 0});

  final String name;

  /// 邏輯像素（dp）。
  final Size size;
  final double textScale;

  /// 鍵盤佔掉的高度（dp）。
  final double keyboard;

  ScreenCase withKeyboard([double height = 280]) =>
      ScreenCase('$name + keyboard', size, textScale: textScale, keyboard: height);

  @override
  String toString() => name;
}

/// 小螢幕手機、系統字體放大 1.3 倍（#79 的驗收條件）。
const smallPhoneLargeText = ScreenCase('360x640 @1.3x text', Size(360, 640), textScale: 1.3);

/// 平板橫向，同樣放大字體。
const tabletLandscape = ScreenCase('1280x800 landscape @1.3x text', Size(1280, 800), textScale: 1.3);

const layoutCases = [smallPhoneLargeText, tabletLandscape];

const _devicePixelRatio = 3.0;

/// 把測試的 view 設成 [screen]；測試結束時自動還原。
void useScreen(WidgetTester tester, ScreenCase screen) {
  tester.view
    ..devicePixelRatio = _devicePixelRatio
    ..physicalSize = screen.size * _devicePixelRatio
    ..padding = const FakeViewPadding(top: 24 * _devicePixelRatio)
    ..viewInsets = FakeViewPadding(bottom: screen.keyboard * _devicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = screen.textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });
}

/// 打開或收起鍵盤（[height] dp）。
void setKeyboard(WidgetTester tester, double height) {
  tester.view.viewInsets = FakeViewPadding(bottom: height * _devicePixelRatio);
}
