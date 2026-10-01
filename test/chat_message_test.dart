import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/models/chat_message.dart';

void main() {
  test('带图片的 user 消息转为多段 content API 格式', () {
    final m = ChatMessage(
      id: 'u1',
      role: 'user',
      content: '这是什么？',
      images: ['data:image/jpeg;base64,QUJD'],
    );
    final api = m.toApiJson();
    expect(api['role'], 'user');
    final parts = api['content'] as List;
    expect(parts, hasLength(2));
    expect(parts[0], {'type': 'text', 'text': '这是什么？'});
    expect(parts[1]['type'], 'image_url');
    expect(parts[1]['image_url']['url'], 'data:image/jpeg;base64,QUJD');
  });

  test('只有图片没有文本时不含 text 段', () {
    final m = ChatMessage(
      id: 'u2',
      role: 'user',
      content: '',
      images: ['data:image/jpeg;base64,QUJD'],
    );
    final parts = m.toApiJson()['content'] as List;
    expect(parts, hasLength(1));
    expect(parts[0]['type'], 'image_url');
  });

  test('纯文本消息保持字符串 content', () {
    final m = ChatMessage(id: 'u3', role: 'user', content: '你好');
    expect(m.toApiJson(), {'role': 'user', 'content': '你好'});
  });

  test('assistant 消息不受 images 影响', () {
    final m = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: '回答',
      images: ['data:image/jpeg;base64,QUJD'], // 理论上不会出现，但应被忽略
    );
    final api = m.toApiJson();
    expect(api['content'], '回答');
    expect(api.containsKey('tool_calls'), isFalse);
  });

  test('toJson/fromJson 往返保留图片', () {
    final m = ChatMessage(
      id: 'u4',
      role: 'user',
      content: '看图',
      images: ['data:image/png;base64,WFla', 'data:image/png;base64,MTIz'],
    );
    final restored = ChatMessage.fromJson(m.toJson());
    expect(restored.images, m.images);
    expect(restored.content, m.content);
    expect(restored.role, m.role);
  });
}
