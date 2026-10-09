import 'package:flutter/material.dart';

import '../theme.dart';
import 'status_bar_area.dart';

/// 隐私协议页：常规静态文本，生效日期与更新说明放在顶部。
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: scaffoldBg(context),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const StatusBarArea(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  BackButton(onPressed: () => Navigator.of(context).pop()),
                  const SizedBox(width: 4),
                  const Text('隐私协议',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                child:
                    DefaultTextStyle(style: TextStyle(fontSize: 14.5, height: 1.6, color: onSurface(context, 0.85)), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('生效日期：2026 年 10 月 10 日',
                        style: TextStyle(fontSize: 12.5)),
                    SizedBox(height: 16),
                    _H('一、我们如何收集信息'),
                    _P('Orion Agent 是运行在你手机上的智能助手。'
                        '你的对话内容、会话记录、记忆条目、知识库文档以及'
                        '模型配置默认只保存在本机存储中，我们不上传、'
                        '不同步、也不出售这些数据。'),
                    _P('仅当你主动登录「云服务」并使用云端模型 / 云端 Agent '
                        '时，你当次发送的消息才会经由我们的服务器转发给'
                        '所选择的模型服务以生成回答；服务器只为完成转发'
                        '而临时处理这些内容。'),
                    _H('二、信息的使用'),
                    _P('1. 本地功能（对话、记忆、知识库、工具调用等）'
                        '完全在设备本地完成，不依赖网络上传个人数据。\n'
                        '2. 你调用联网搜索、网页抓取等工具时，相应的'
                        '查询内容会发送给对应第三方服务。\n'
                        '3. 云端服务会记录必要的账号信息（邮箱、套餐、'
                        '用量计数）用于鉴权与额度管理。'),
                    _H('三、信息的存储与安全'),
                    _P('本地数据存储在应用私有目录，卸载应用即全部删除。'
                        '云端传输使用 HTTPS 加密；云端会话数据保存在'
                        '受访问控制的数据库中，仅用于向你提供服务。'),
                    _H('四、第三方服务'),
                    _P('当你使用云端模型或自定义 AI 提供商时，消息内容'
                        '会按你的指令发送给相应的模型服务商，并受其'
                        '隐私政策约束。我们不会向第三方出售你的个人信息。'),
                    _H('五、你的权利'),
                    _P('你可以随时在应用内删除会话、记忆与知识库数据'
                        '（「我的 → 清空所有会话」等）；退出云服务登录后，'
                        '云端将不再以你的账号处理新的请求。'),
                    _H('六、协议更新'),
                    _P('本协议可能随功能迭代更新，重要变更会在应用内'
                        '公告提醒。继续使用即视为同意更新后的协议。'),
                    _H('七、联系我们'),
                    _P('如对本协议有任何疑问，可通过应用内「关于」页'
                        '提供的渠道与我们联系。'),
                    SizedBox(height: 24),
                  ],
                )),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _H extends StatelessWidget {
  final String text;
  const _H(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 14),
      child: Text(text,
          style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: onSurface(context))),
    );
  }
}

class _P extends StatelessWidget {
  final String text;
  const _P(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text),
    );
  }
}
