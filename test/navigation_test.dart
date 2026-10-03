import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/providers/providers.dart';
import 'package:pocket_agent/services/navigation_service.dart';

void main() {
  // 每个用例一个独立容器：provider 状态互不污染。
  // 用 setUp/tearDown 而不是在顶层函数里 addTearDown，避免依赖隐式 test 上下文。
  late ProviderContainer c;

  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  group('NavPayload / HomeTab 契约', () {
    test('Tab 索引与 HomeShell 的 children 顺序一致', () {
      expect(HomeTab.chat, 0);
      expect(HomeTab.tasks, 1);
      expect(HomeTab.skills, 2);
      expect(HomeTab.profile, 3);
    });

    test('聊天通知的 payload 是 NavPayload.chat', () {
      // notification_service.notifyAnswerDone 用的是这个常量，
      // 两边不一致会导致点击后无反应
      expect(NavPayload.chat, 'chat');
    });
  });

  group('NavigationService.handlePayload', () {
    test('chat 写入跳转到对话 Tab 的意图', () {
      final nav = c.read(navigationServiceProvider);

      expect(nav.handlePayload(NavPayload.chat), isTrue);
      final intent = c.read(navIntentProvider);
      expect(intent, isNotNull);
      expect(intent!.tab, HomeTab.chat, reason: '实际 tab=${intent.tab}');
    });

    test('tasks / profile 各自映射到对应 Tab', () {
      final nav = c.read(navigationServiceProvider);

      nav.handlePayload(NavPayload.tasks);
      expect(c.read(navIntentProvider)!.tab, HomeTab.tasks);

      nav.handlePayload(NavPayload.profile);
      expect(c.read(navIntentProvider)!.tab, HomeTab.profile);
    });

    test('未知 payload 返回 false 且不写意图', () {
      final nav = c.read(navigationServiceProvider);

      expect(nav.handlePayload('some_unknown_deeplink'), isFalse);
      expect(c.read(navIntentProvider), isNull, reason: '未知 payload 不应产生跳转');
    });

    test('null payload 安全返回 false', () {
      expect(c.read(navigationServiceProvider).handlePayload(null), isFalse);
      expect(c.read(navIntentProvider), isNull);
    });
  });

  group('连续相同目标', () {
    // StateProvider 只在值不相等时才通知。若 NavIntent 少了 seq，
    // 连续点两条相同通知（如两次回答完成）第二次会被吞掉。
    test('相同 tab 连续触发会产生新意图（靠 seq 区分）', () {
      final nav = c.read(navigationServiceProvider);

      nav.handlePayload(NavPayload.chat);
      final first = c.read(navIntentProvider)!;
      nav.handlePayload(NavPayload.chat);
      final second = c.read(navIntentProvider)!;

      expect(second.seq, greaterThan(first.seq),
          reason: 'seq 必须递增，否则第二次点击不会触发跳转');
      expect(second, isNot(equals(first)));
    });

    test('消费（置 null）后可再次触发', () {
      final nav = c.read(navigationServiceProvider);

      nav.handlePayload(NavPayload.chat);
      c.read(navIntentProvider.notifier).state = null; // 模拟 HomeShell 消费
      expect(c.read(navIntentProvider), isNull);

      nav.handlePayload(NavPayload.chat);
      expect(c.read(navIntentProvider), isNotNull);
    });
  });

  group('冷启动场景', () {
    // 通知回调可能在 runApp 之前触发，那时没有 widget 可跳转。
    // 正确行为是"先记账"，HomeShell 首帧后主动读取并执行。
    //
    // 注意：StateProvider 在监听注册前写入的值【不会补发】通知，
    // 所以 HomeShell 必须在首帧主动 read 一次 —— 这正是
    // HomeShell._consumeIntent 存在的理由，两者必须成对存在。
    test('HomeShell 尚未挂载时写入意图不会丢失', () {
      c.read(navigationServiceProvider).handlePayload(NavPayload.chat);
      expect(c.read(navIntentProvider), isNotNull,
          reason: '冷启动时意图应被保留，等首帧后执行');
    });

    test('首帧主动读取能取回冷启动期间写入的意图', () {
      // 模拟：runApp 前写入 → HomeShell 首帧 read
      c.read(navigationServiceProvider).handlePayload(NavPayload.tasks);
      final intent = c.read(navIntentProvider); // ← _consumeIntent 的核心动作
      expect(intent, isNotNull);
      expect(intent!.tab, HomeTab.tasks);

      // 消费掉，避免旋转屏幕/重建时重复跳转
      c.read(navIntentProvider.notifier).state = null;
      expect(c.read(navIntentProvider), isNull);
    });

    test('预填文本随意图一起保存', () {
      c.read(navigationServiceProvider).goToTab(HomeTab.chat, prefill: '继续刚才的问题');
      final intent = c.read(navIntentProvider)!;
      expect(intent.prefill, '继续刚才的问题');
      expect(intent.tab, HomeTab.chat);
    });

    test('NavigationService 不越权直接写 prefillProvider', () {
      // prefillProvider 只应在真正跳到聊天页时才写（由 HomeShell 负责），
      // 否则跳到"任务"Tab 也会污染聊天输入框
      c.read(navigationServiceProvider).goToTab(HomeTab.tasks, prefill: 'x');
      expect(c.read(prefillProvider), '');
    });
  });

  group('NavIntent 相等性', () {
    test('seq 不同则不相等', () {
      const a = NavIntent(0, seq: 1);
      const b = NavIntent(0, seq: 2);
      expect(a, isNot(equals(b)));
    });

    test('完全相同则相等', () {
      const a = NavIntent(1, prefill: 'hi', seq: 3);
      const b = NavIntent(1, prefill: 'hi', seq: 3);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
