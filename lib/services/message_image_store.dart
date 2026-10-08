import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

/// 消息图片落盘（评估项 P2，v0.2.27-beta）。
///
/// 此前消息图片以 base64 data URL 存进 SQLite 的 imagesJson 列，一张
/// 1600px 图可达数百 KB，随消息行一起进出内存，是启动慢、列表卡、
/// 备份体积大的直接原因之一。改为：图片写入应用目录文件，DB 只存
/// 相对路径引用；内存里的 ChatMessage.images 仍是 data URL，UI 零改动。
///
/// 引用（ref）格式：
/// - 新数据：`img/<消息id>_<序号>.jpg`（相对应用支持目录）
/// - 旧数据/写文件失败的兜底：data URL 原样（读写时直接透传）
///
/// imagesJson 列的 JSON 字符串数组结构不变，只是元素语义扩展，
/// 无需 schema 迁移；旧数据的 data URL 在该消息下次落库时自然转为文件。
class MessageImageStore {
  MessageImageStore._();
  static final MessageImageStore instance = MessageImageStore._();

  Directory? _base;

  /// 仅供测试注入临时目录。
  void debugOverrideDir(Directory dir) => _base = dir;

  Future<Directory> _dir() async {
    final b = _base;
    if (b != null) return b;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
        '${support.path}${Platform.pathSeparator}message_images');
    dir.createSync(recursive: true);
    return _base = dir;
  }

  /// 落库前调用：data URL → 写文件，返回引用列表。
  /// 单张失败降级为原样存 data URL（消息本身绝不能丢）。
  Future<List<String>> store(String messageId, List<String> images) async {
    final out = <String>[];
    for (var i = 0; i < images.length; i++) {
      final img = images[i];
      if (!img.startsWith('data:')) {
        out.add(img);
        continue;
      }
      try {
        final comma = img.indexOf(',');
        final bytes = base64Decode(comma < 0 ? img : img.substring(comma + 1));
        final dir = await _dir();
        final rel = 'img/${messageId}_$i.jpg';
        final f = File(
            '${dir.path}${Platform.pathSeparator}img${Platform.pathSeparator}${messageId}_$i.jpg');
        await f.create(recursive: true);
        await f.writeAsBytes(bytes, flush: true);
        out.add(rel);
      } catch (e) {
        AppLog.e('消息图片写盘失败，降级为内联存储', e);
        out.add(img);
      }
    }
    return out;
  }

  /// 读取时调用：引用 → data URL。
  /// 旧数据（data URL）透传；文件缺失/损坏时丢弃该张图并记日志——
  /// 一张图丢失不应导致整个会话加载失败。
  Future<List<String>> resolve(List<String> refs) async {
    final out = <String>[];
    for (final ref in refs) {
      if (!ref.startsWith('img/')) {
        out.add(ref);
        continue;
      }
      try {
        final dir = await _dir();
        final bytes = await File('${dir.path}${Platform.pathSeparator}'
                '${ref.replaceAll('/', Platform.pathSeparator)}')
            .readAsBytes();
        out.add('data:image/jpeg;base64,${base64Encode(bytes)}');
      } catch (e) {
        AppLog.e('消息图片读取失败，已跳过：$ref', e);
      }
    }
    return out;
  }

  /// 备份导出用：把引用批量还原为 data URL，保证备份文件自包含。
  Future<List<String>> resolveJson(String imagesJson) async {
    try {
      final list = (jsonDecode(imagesJson) as List? ?? const [])
          .cast<String>()
          .toList();
      // 必须 await：否则 resolve 抛出的异常会绕过下面的 catch
      return await resolve(list);
    } catch (e) {
      AppLog.e('imagesJson 解析失败，按空图片处理', e);
      return const [];
    }
  }

  /// 备份导入用：把备份里的 data URL 转为文件引用（返回 jsonEncode 后的列值）。
  Future<String> storeJson(String messageId, String imagesJson) async {
    try {
      final list = (jsonDecode(imagesJson) as List? ?? const [])
          .cast<String>()
          .toList();
      return jsonEncode(await store(messageId, list));
    } catch (e) {
      AppLog.e('imagesJson 落盘转换失败，按空图片处理', e);
      return '[]';
    }
  }
}

/// 便于在无 IO 的纯计算处引用（如测试），base64 编码工具方法。
@visibleForTesting
String encodeDataUrl(List<int> bytes) =>
    'data:image/jpeg;base64,${base64Encode(bytes)}';
