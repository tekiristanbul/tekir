import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/network/api_client.dart';
import 'package:app/features/blocks/data/blocks_api.dart';

// Mirrors reports_api_test.dart's _FakeAdapter exactly.
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

BlocksApi _apiWith(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  return BlocksApi(ApiClient(dio: dio));
}

void main() {
  group('BlocksApi.block', () {
    test('posts only the target account id — never a blocker', () async {
      final adapter = _FakeAdapter(statusCode: 204);
      await _apiWith(adapter).block('user-1');

      expect(adapter.lastOptions?.path, '/v1/me/blocks');
      expect(adapter.lastOptions?.method, 'POST');
      expect(adapter.lastOptions?.data, {'blocked_user_id': 'user-1'});
    });

    test('maps 401 to BlockUnauthorizedException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 401));
      expect(
        () => api.block('user-1'),
        throwsA(isA<BlockUnauthorizedException>()),
      );
    });

    test('maps 404 to BlockTargetNotFoundException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 404));
      expect(
        () => api.block('user-1'),
        throwsA(isA<BlockTargetNotFoundException>()),
      );
    });

    test('maps 400 to BlockValidationException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 400));
      expect(
        () => api.block('user-1'),
        throwsA(isA<BlockValidationException>()),
      );
    });

    test('maps 500 to BlockServerException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 500));
      expect(() => api.block('user-1'), throwsA(isA<BlockServerException>()));
    });

    test('maps a connection failure to BlockNetworkException', () async {
      final api = _apiWith(_ThrowingAdapter());
      expect(() => api.block('user-1'), throwsA(isA<BlockNetworkException>()));
    });
  });

  group('BlocksApi.unblock', () {
    test('deletes the account id in the path', () async {
      final adapter = _FakeAdapter(statusCode: 204);
      await _apiWith(adapter).unblock('user-1');

      expect(adapter.lastOptions?.path, '/v1/me/blocks/user-1');
      expect(adapter.lastOptions?.method, 'DELETE');
    });
  });

  group('BlocksApi.listBlocked', () {
    test('parses the list, keeping a null display name', () async {
      final adapter = _FakeAdapter(
        statusCode: 200,
        bodyJson: [
          {
            'user_id': 'user-1',
            'display_name': 'Komşu',
            'created_at': '2026-08-14T09:00:00Z',
          },
          {
            'user_id': 'user-2',
            'display_name': null,
            'created_at': '2026-08-13T09:00:00Z',
          },
        ],
      );

      final list = await _apiWith(adapter).listBlocked();

      expect(adapter.lastOptions?.path, '/v1/me/blocks');
      expect(list.length, 2);
      expect(list.first.userId, 'user-1');
      expect(list.first.displayName, 'Komşu');
      expect(list.last.displayName, isNull);
    });

    test('treats an empty body as an empty list', () async {
      final list = await _apiWith(
        _FakeAdapter(statusCode: 200, bodyJson: <dynamic>[]),
      ).listBlocked();
      expect(list, isEmpty);
    });
  });
}
