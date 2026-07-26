import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/network/api_client.dart';
import 'package:app/features/follow/data/follows_api.dart';

// Mirrors cat_detail_api_update_test.dart's _FakeAdapter exactly.
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

final _followsResponse = [
  {
    'id': 'cat-1',
    'name': 'tekir',
    'primary_photo': 'https://placecats.com/millie/300/200',
    'area': {'lat': 41.0256, 'lng': 28.9744},
    'area_label': 'Galata Kulesi çevresi, Beyoğlu',
    'active_alert': null,
    'last_update_at': '2026-01-01T12:00:00Z',
  },
];

FollowsApi _apiWith(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  return FollowsApi(ApiClient(dio: dio));
}

void main() {
  group('FollowsApi.follow', () {
    test('posts to the correct path', () async {
      final adapter = _FakeAdapter(statusCode: 204);
      final api = _apiWith(adapter);

      await api.follow('cat-1');

      expect(adapter.lastOptions?.path, '/v1/cats/cat-1/follow');
      expect(adapter.lastOptions?.method, 'POST');
    });

    test('401 maps to FollowUnauthorizedException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 401));
      await expectLater(
        api.follow('cat-1'),
        throwsA(isA<FollowUnauthorizedException>()),
      );
    });

    test('404 maps to FollowCatNotFoundException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 404));
      await expectLater(
        api.follow('cat-1'),
        throwsA(isA<FollowCatNotFoundException>()),
      );
    });

    test('500 maps to FollowServerException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 500));
      await expectLater(
        api.follow('cat-1'),
        throwsA(isA<FollowServerException>()),
      );
    });

    test('a connection failure maps to FollowNetworkException', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
      dio.httpClientAdapter = _ThrowingAdapter();
      final api = FollowsApi(ApiClient(dio: dio));

      await expectLater(
        api.follow('cat-1'),
        throwsA(isA<FollowNetworkException>()),
      );
    });
  });

  group('FollowsApi.unfollow', () {
    test('sends a delete to the correct path', () async {
      final adapter = _FakeAdapter(statusCode: 204);
      final api = _apiWith(adapter);

      await api.unfollow('cat-1');

      expect(adapter.lastOptions?.path, '/v1/cats/cat-1/follow');
      expect(adapter.lastOptions?.method, 'DELETE');
    });

    test('401 maps to FollowUnauthorizedException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 401));
      await expectLater(
        api.unfollow('cat-1'),
        throwsA(isA<FollowUnauthorizedException>()),
      );
    });
  });

  group('FollowsApi.fetchFollows', () {
    test(
      'gets the correct path and parses the response into CatMarkers',
      () async {
        final adapter = _FakeAdapter(
          statusCode: 200,
          bodyJson: _followsResponse,
        );
        final api = _apiWith(adapter);

        final cats = await api.fetchFollows();

        expect(adapter.lastOptions?.path, '/v1/me/follows');
        expect(adapter.lastOptions?.method, 'GET');
        expect(cats, hasLength(1));
        expect(cats.first.id, 'cat-1');
        expect(cats.first.name, 'tekir');
      },
    );

    test('an empty list response is a valid empty result', () async {
      final adapter = _FakeAdapter(statusCode: 200, bodyJson: <dynamic>[]);
      final api = _apiWith(adapter);

      final cats = await api.fetchFollows();

      expect(cats, isEmpty);
    });

    test('401 maps to FollowUnauthorizedException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 401));
      await expectLater(
        api.fetchFollows(),
        throwsA(isA<FollowUnauthorizedException>()),
      );
    });
  });
}
