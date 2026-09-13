// 弹窗卡片布局测试：验证「收缩到内容大小 + 垂直居中」，防止再次出现整屏白板的问题。
// 运行：flutter test test/dialog_layout_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro_app/main.dart';

void main() {
  testWidgets('弹窗卡片：收缩到内容高度并垂直居中', (WidgetTester tester) async {
    // 模拟一台 360x800 逻辑像素的手机
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (BuildContext c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      }),
    ));

    showDialog<void>(
      context: ctx,
      builder: (_) => AppDialogCard(
        title: '新建任务',
        actions: <Widget>[
          const Text('取消'),
          const Text('保存'),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            SizedBox(height: 46, child: ColoredBox(color: Color(0xFFF2F2F7), child: SizedBox(width: double.infinity))),
            SizedBox(height: 16),
            SizedBox(height: 46, child: ColoredBox(color: Color(0xFFF2F2F7), child: SizedBox(width: double.infinity))),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1) 卡片高度应远小于屏幕（收缩到内容大小），而不是撑满整屏
    final Rect cardRect = tester.getRect(find.byKey(const ValueKey<String>('app_dialog_card_body')));
    expect(cardRect.height, lessThan(400), reason: '卡片应收缩到内容高度（当前 ${cardRect.height}）');
    expect(cardRect.height, greaterThan(100), reason: '卡片不应小于内容');

    // 2) 应垂直居中：上边距与下边距基本相等
    final double topGap = cardRect.top;
    final double bottomGap = 800 - cardRect.bottom;
    expect((topGap - bottomGap).abs(), lessThan(40),
        reason: '卡片应垂直居中（上 $topGap / 下 $bottomGap）');
  });

  testWidgets('弹窗卡片：内容超长时限制在屏幕内且可滚动', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (BuildContext c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      }),
    ));

    showDialog<void>(
      context: ctx,
      builder: (_) => AppDialogCard(
        title: '超长内容',
        actions: <Widget>[const Text('好')],
        child: SingleChildScrollView(
          child: Column(
            children: List<Widget>.generate(
              30,
              (int i) => const SizedBox(height: 60, child: Text('内容行')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect cardRect = tester.getRect(find.byKey(const ValueKey<String>('app_dialog_card_body')));
    expect(cardRect.height, lessThanOrEqualTo(800 - 90), reason: '不能超出屏幕');
    expect(cardRect.height, greaterThan(600), reason: '应利用可用空间显示尽可能多的内容');
  });
}
