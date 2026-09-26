import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 三键(两键)导航的机子上,把整个应用托到系统导航栏上面。
///
/// targetSdk 35 起,Android 15+ 强制 edge-to-edge:应用一直画到屏幕最底,系统
/// 导航栏盖在上面,底部避让全靠各处自己留 `padding.bottom`。手势导航那根横条
/// 只有 16–24dp,漏留了也就压一点边;三键导航栏有 48dp,漏留的地方底部按钮、
/// 列表末行会被整条盖住(用户反馈「被金刚键挡住」)。弹层、二级页、列表末尾
/// 各有各的写法,逐处补补不全,新写的界面也还会漏 —— 挂在 MaterialApp.builder
/// 上统一收掉。
///
/// 做法是退回 edge-to-edge 之前的布局:导航栏够高(≥ [_kButtonBarMin])时,
/// 应用区底边收到导航栏上沿,MediaQuery 的底部 padding 清零、size 同步变矮,
/// 腾出来的那条涂成底栏同色。手势导航不动,照旧沉浸到底。
///
/// 软键盘:让出的高度取 `padding.bottom`(引擎给的是导航栏高减去键盘已升起的
/// 高度),键盘升起时逐帧缩到 0;`viewInsets` 原样往下传。这样键盘从导航栏
/// 后面升起的过程中,内容底边始终停在两者中较高的那条上沿,不会跳。
///
/// 手势导航下这几层照样包着(那条高 0)。转屏、换导航方式时如果把包装加上
/// 或拆掉,底下整棵 Navigator 会重建,页面状态全丢。
class NavBarGuard extends StatelessWidget {
  const NavBarGuard({super.key, required this.child});

  final Widget child;

  /// 手势横条最高 24dp(AOSP),三键/两键导航栏 48dp,取两者之间。
  static const _kButtonBarMin = 32.0;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 是不是三键看 viewPadding(不随键盘变),让多少看 padding(随键盘收)
    final guarded = mq.viewPadding.bottom >= _kButtonBarMin;
    final lift = guarded ? mq.padding.bottom : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: MediaQuery(
            data: guarded
                ? mq
                      .removePadding(removeBottom: true)
                      .copyWith(
                        size: Size(mq.size.width, mq.size.height - lift),
                        systemGestureInsets: mq.systemGestureInsets.copyWith(
                          bottom: math.max(
                            0.0,
                            mq.systemGestureInsets.bottom - lift,
                          ),
                        ),
                      )
                : mq,
            child: child,
          ),
        ),
        // 和主界面底栏同色:在主界面上看,底栏照旧一直铺到屏幕底
        ColoredBox(
          color:
              NavigationBarTheme.of(context).backgroundColor ??
              Theme.of(context).colorScheme.surfaceContainer,
          child: SizedBox(height: lift),
        ),
      ],
    );
  }
}
