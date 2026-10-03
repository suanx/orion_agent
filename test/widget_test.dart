// 说明：此文件需保留——CI 的 `flutter create .` 在文件缺失时会重新生成
// 引用 MyApp 的默认模板导致 Analyze 失败。放一个真实断言避免成为死文件。
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/text_chunker.dart';

void main() {
  test('chunkText 段落合并（冒烟）', () {
    expect(chunkText('一\n\n二'), ['一\n二']);
  });
}
