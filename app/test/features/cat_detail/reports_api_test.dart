import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/network/api_client.dart';
import 'package:app/features/cat_detail/data/reports_api.dart';

// Mirrors follows_api_test.dart's _FakeAdapter exactly.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.statusCode, this.bodyJson});

  final int statusCode;
  final dynamic bodyJson;
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return ResponseBody.fromString(
      bodyJson == null ? '' : jsonEncode(bodyJson),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'offline',
    );
  }

  @override
  void close({bool force = false}) {}
}

ReportsApi _apiWith(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  return ReportsApi(ApiClient(dio: dio));
}

void main() {
  group('ReportsApi.submitReport', () {
    test('posts target_type/target_id/reason/note to /v1/reports', () async {
      final adapter = _FakeAdapter(
        statusCode: 201,
        bodyJson: {
          'id': 'report-1',
          'target_type': 'cat',
          'target_id': 'cat-1',
          'reason': 'spam',
          'note': null,
          'status': 'open',
          'created_at': '2026-01-01T12:00:00Z',
        },
      );
      final api = _apiWith(adapter);

      await api.submitReport(
        targetType: 'cat',
        targetId: 'cat-1',
        reason: 'spam',
      );

      expect(adapter.lastOptions?.path, '/v1/reports');
      expect(adapter.lastOptions?.method, 'POST');
      expect(adapter.lastOptions?.data, {
        'target_type': 'cat',
        'target_id': 'cat-1',
        'reason': 'spam',
        'note': null,
      });
    });

    test('passes the optional note through', () async {
      final adapter = _FakeAdapter(statusCode: 201);
      final api = _apiWith(adapter);

      await api.submitReport(
        targetType: 'media',
        targetId: 'media-1',
        reason: 'other',
        note: 'plaka görünüyor',
      );

      expect(adapter.lastOptions?.data['note'], 'plaka görünüyor');
    });

    test('400 maps to ReportValidationException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 400));
      await expectLater(
        api.submitReport(targetType: 'cat', targetId: 'cat-1', reason: 'other'),
        throwsA(isA<ReportValidationException>()),
      );
    });

    test('401 maps to ReportUnauthorizedException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 401));
      await expectLater(
        api.submitReport(targetType: 'cat', targetId: 'cat-1', reason: 'spam'),
        throwsA(isA<ReportUnauthorizedException>()),
      );
    });

    test('404 maps to ReportTargetNotFoundException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 404));
      await expectLater(
        api.submitReport(
          targetType: 'update',
          targetId: 'upd-1',
          reason: 'spam',
        ),
        throwsA(isA<ReportTargetNotFoundException>()),
      );
    });

    test('500 maps to ReportServerException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 500));
      await expectLater(
        api.submitReport(targetType: 'cat', targetId: 'cat-1', reason: 'spam'),
        throwsA(isA<ReportServerException>()),
      );
    });

    test('a connection failure maps to ReportNetworkException', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
      dio.httpClientAdapter = _ThrowingAdapter();
      final api = ReportsApi(ApiClient(dio: dio));

      await expectLater(
        api.submitReport(targetType: 'cat', targetId: 'cat-1', reason: 'spam'),
        throwsA(isA<ReportNetworkException>()),
      );
    });
  });
}
