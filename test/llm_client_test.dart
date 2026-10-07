import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/llm_client.dart';

/// LlmClient 故障分类纯函数的回归测试（chatStream 自动重试的判定核心）。
///
/// isTransientFailure 管「原地重试是否有意义」，isKeyFailure 管
/// 「换 Key 是否有意义」。分类错了要么白烧重试，要么把可恢复的
/// 网络抖动当死刑——直接表现为「对话经常断」（v0.2.31 前的真实故障）。
void main() {
  RequestOptions opts() => RequestOptions(path: '/chat/completions');

  DioException dio(DioExceptionType type, {int? status}) => DioException(
        requestOptions: opts(),
        type: type,
        response: status == null
            ? null
            : Response<void>(requestOptions: opts(), statusCode: status),
      );

  group('isTransientFailure：临时性故障（可原地重试）', () {
    test('连接建立/发送/接收超时、连接被重置', () {
      expect(LlmClient.isTransientFailure(
          dio(DioExceptionType.connectionTimeout)), isTrue);
      expect(LlmClient.isTransientFailure(
          dio(DioExceptionType.sendTimeout)), isTrue);
      expect(LlmClient.isTransientFailure(
          dio(DioExceptionType.receiveTimeout)), isTrue);
      expect(LlmClient.isTransientFailure(
          dio(DioExceptionType.connectionError)), isTrue);
    });

    test('5xx 与 429（限流）服务端故障', () {
      expect(
          LlmClient.isTransientFailure(
              dio(DioExceptionType.badResponse, status: 500)),
          isTrue);
      expect(
          LlmClient.isTransientFailure(
              dio(DioExceptionType.badResponse, status: 502)),
          isTrue);
      expect(
          LlmClient.isTransientFailure(
              dio(DioExceptionType.badResponse, status: 429)),
          isTrue);
    });

    test('socket 级错误（NAT 超时等）', () {
      expect(
          LlmClient.isTransientFailure(
              const SocketException('network unreachable')),
          isTrue);
    });

    test('SSE 空闲超时（普通 Exception，按消息识别）', () {
      expect(LlmClient.isTransientFailure(
          Exception('模型响应超时（连续 180 秒未收到任何数据）')), isTrue);
    });
  });

  group('isTransientFailure：非临时性故障（不重试）', () {
    test('用户取消与证书错误', () {
      expect(LlmClient.isTransientFailure(dio(DioExceptionType.cancel)),
          isFalse);
      expect(LlmClient.isTransientFailure(
          dio(DioExceptionType.badCertificate)), isFalse);
    });

    test('4xx 参数/内容错误（重试也一样）', () {
      expect(
          LlmClient.isTransientFailure(
              dio(DioExceptionType.badResponse, status: 400)),
          isFalse);
      expect(
          LlmClient.isTransientFailure(
              dio(DioExceptionType.badResponse, status: 404)),
          isFalse);
    });

    test('普通业务异常（如网关错误帧、Key 未配置）', () {
      expect(LlmClient.isTransientFailure(Exception('未配置 API Key')), isFalse);
      expect(LlmClient.isTransientFailure(Exception('模型服务返回错误：余额不足')),
          isFalse);
    });
  });

  group('isKeyFailure：换 Key 重试的判定', () {
    test('401/402/403/429 命中，5xx 与网络错误不命中', () {
      for (final code in [401, 402, 403, 429]) {
        expect(
            LlmClient.isKeyFailure(
                dio(DioExceptionType.badResponse, status: code)),
            isTrue,
            reason: 'HTTP $code 应允许换 Key');
      }
      expect(
          LlmClient.isKeyFailure(
              dio(DioExceptionType.badResponse, status: 500)),
          isFalse);
      expect(LlmClient.isKeyFailure(dio(DioExceptionType.connectionError)),
          isFalse);
      expect(LlmClient.isKeyFailure(Exception('普通异常')), isFalse);
    });
  });
}
