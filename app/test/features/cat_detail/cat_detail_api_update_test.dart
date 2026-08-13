import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/network/api_client.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';

// A fake adapter that captures the last request and answers with a
// pre-configured status/body — mirrors the pattern used by
// test/core/identity/device_identity_service_test.dart and
// test/core/network/device_interceptor_test.dart, since this is the first
// test in this feature to exercise CatDetailApi against a real Dio.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.statusCode, required this.bodyJson});

  final int statusCode;
  final Map<String, dynamic> bodyJson;
  RequestOptions? lastOptions;
  String? lastRequestBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    if (requestStream != null) {
      final bytes = await requestStream.expand((chunk) => chunk).toList();
      lastRequestBody = utf8.decode(bytes);
    }
    return ResponseBody.fromString(
      jsonEncode(bodyJson),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final _createdResponse = {
  'id': 'upd-1',
  'kind': 'ordinary',
  'statuses': ['seen', 'water_provided'],
  'comment': 'kase boştu, doldurduk',
  'created_at': '2026-07-24T10:00:00Z',
  'needs_help_category': null,
  'needs_help_category_label': null,
  'needs_help_expires_at': null,
  'needs_help_active': null,
};

CatDetailApi _apiWith(_FakeAdapter adapter, {String? deviceToken}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  if (deviceToken != null) {
    dio.options.headers['X-Device-Token'] = deviceToken;
  }
  final apiClient = ApiClient(dio: dio);
  return CatDetailApi(apiClient);
}

void main() {
  group('CatDetailApi.createUpdate', () {
    test('posts to the correct path with statuses and comment', () async {
      final adapter = _FakeAdapter(statusCode: 201, bodyJson: _createdResponse);
      final api = _apiWith(adapter);

      await api.createUpdate(
        'cat-1',
        statuses: const ['seen', 'water_provided'],
        idempotencyKey: 'idem-1',
        comment: 'kase boştu, doldurduk',
      );

      expect(adapter.lastOptions?.path, '/v1/cats/cat-1/updates');
      expect(adapter.lastOptions?.method, 'POST');
      final sentBody = jsonDecode(adapter.lastRequestBody!) as Map;
      expect(sentBody['statuses'], ['seen', 'water_provided']);
      expect(sentBody['comment'], 'kase boştu, doldurduk');
    });

    test('sends comment as null, not an empty string, when omitted', () async {
      final adapter = _FakeAdapter(statusCode: 201, bodyJson: _createdResponse);
      final api = _apiWith(adapter);

      await api.createUpdate(
        'cat-1',
        statuses: const ['seen'],
        idempotencyKey: 'idem-1',
      );

      final sentBody = jsonDecode(adapter.lastRequestBody!) as Map;
      expect(sentBody.containsKey('comment'), isTrue);
      expect(sentBody['comment'], isNull);
    });

    test('sends media_id when a photo was uploaded first', () async {
      final adapter = _FakeAdapter(statusCode: 201, bodyJson: _createdResponse);
      final api = _apiWith(adapter);

      await api.createUpdate(
        'cat-1',
        statuses: const ['seen'],
        idempotencyKey: 'idem-1',
        mediaId: 'media-1',
      );

      final sentBody = jsonDecode(adapter.lastRequestBody!) as Map;
      expect(sentBody['media_id'], 'media-1');
    });

    test('carries the device credential set on the shared client', () async {
      final adapter = _FakeAdapter(statusCode: 201, bodyJson: _createdResponse);
      final api = _apiWith(adapter, deviceToken: 'tok-abc');

      await api.createUpdate(
        'cat-1',
        statuses: const ['seen'],
        idempotencyKey: 'idem-1',
      );

      expect(adapter.lastOptions?.headers['X-Device-Token'], 'tok-abc');
    });

    test('sends Idempotency-Key as its own header (issue #80 product-owner '
        'review, finding 4)', () async {
      final adapter = _FakeAdapter(statusCode: 201, bodyJson: _createdResponse);
      final api = _apiWith(adapter);

      await api.createUpdate(
        'cat-1',
        statuses: const ['seen'],
        idempotencyKey: 'seen-tap-key',
      );

      expect(adapter.lastOptions?.headers['Idempotency-Key'], 'seen-tap-key');
    });

    test('parses a 201 response into a CatUpdateEntry', () async {
      final adapter = _FakeAdapter(statusCode: 201, bodyJson: _createdResponse);
      final api = _apiWith(adapter);

      final entry = await api.createUpdate(
        'cat-1',
        statuses: const ['seen', 'water_provided'],
        idempotencyKey: 'idem-1',
        comment: 'kase boştu, doldurduk',
      );

      expect(entry.id, 'upd-1');
      expect(entry.statuses, ['seen', 'water_provided']);
      expect(entry.comment, 'kase boştu, doldurduk');
      expect(entry.createdAt, DateTime.parse('2026-07-24T10:00:00Z'));
    });

    test('400 maps to UpdateValidationException', () async {
      final api = _apiWith(
        _FakeAdapter(statusCode: 400, bodyJson: {'error': 'invalid statuses'}),
      );

      await expectLater(
        api.createUpdate(
          'cat-1',
          statuses: const ['seen'],
          idempotencyKey: 'idem-1',
        ),
        throwsA(isA<UpdateValidationException>()),
      );
    });

    test('401 maps to UpdateUnauthorizedException', () async {
      final api = _apiWith(
        _FakeAdapter(
          statusCode: 401,
          bodyJson: {'error': 'invalid device token'},
        ),
      );

      await expectLater(
        api.createUpdate(
          'cat-1',
          statuses: const ['seen'],
          idempotencyKey: 'idem-1',
        ),
        throwsA(isA<UpdateUnauthorizedException>()),
      );
    });

    test('404 maps to CatNotFoundException', () async {
      final api = _apiWith(
        _FakeAdapter(statusCode: 404, bodyJson: {'error': 'cat not found'}),
      );

      await expectLater(
        api.createUpdate(
          'cat-1',
          statuses: const ['seen'],
          idempotencyKey: 'idem-1',
        ),
        throwsA(isA<CatNotFoundException>()),
      );
    });

    test('404 media not found maps to UpdateMediaNotFoundException', () async {
      final api = _apiWith(
        _FakeAdapter(statusCode: 404, bodyJson: {'error': 'media not found'}),
      );

      await expectLater(
        api.createUpdate(
          'cat-1',
          statuses: const ['seen'],
          idempotencyKey: 'idem-1',
          mediaId: 'media-1',
        ),
        throwsA(isA<UpdateMediaNotFoundException>()),
      );
    });

    test('500 maps to UpdateServerException (retryable)', () async {
      final api = _apiWith(
        _FakeAdapter(statusCode: 500, bodyJson: {'error': 'internal error'}),
      );

      await expectLater(
        api.createUpdate(
          'cat-1',
          statuses: const ['seen'],
          idempotencyKey: 'idem-1',
        ),
        throwsA(isA<UpdateServerException>()),
      );
    });

    test(
      'a connection failure (no response) maps to UpdateNetworkException',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
        dio.httpClientAdapter = _ThrowingAdapter();
        final api = CatDetailApi(ApiClient(dio: dio));

        await expectLater(
          api.createUpdate(
            'cat-1',
            statuses: const ['seen'],
            idempotencyKey: 'idem-1',
          ),
          throwsA(isA<UpdateNetworkException>()),
        );
      },
    );

    test(
      'a 2xx response with an empty body maps to UpdateServerException, not a crash',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
        dio.httpClientAdapter = _EmptyBodyAdapter();
        final api = CatDetailApi(ApiClient(dio: dio));

        await expectLater(
          api.createUpdate(
            'cat-1',
            statuses: const ['seen'],
            idempotencyKey: 'idem-1',
          ),
          throwsA(isA<UpdateServerException>()),
        );
      },
    );
  });

  group('CatDetailApi.uploadMedia', () {
    test('posts multipart media and returns the created media id', () async {
      final adapter = _FakeAdapter(
        statusCode: 201,
        bodyJson: {'media_id': 'media-1', 'url': 'https://x/photo.jpg'},
      );
      final api = _apiWith(adapter);

      final mediaId = await api.uploadMedia(
        mediaBytes: Uint8List.fromList([1, 2, 3]),
        mediaFilename: 'photo.jpg',
        idempotencyKey: 'upload-1',
        muted: true,
      );

      expect(mediaId, 'media-1');
      expect(adapter.lastOptions?.path, '/v1/media');
      expect(adapter.lastOptions?.headers['Idempotency-Key'], 'upload-1');
    });

    // issue #194: the composer's mute/unmute toggle must actually reach
    // the server as the multipart body's own "muted" field, not just live
    // as client-side state.
    test('sends the muted field in the multipart body', () async {
      final adapter = _FakeAdapter(
        statusCode: 201,
        bodyJson: {'media_id': 'media-1', 'url': 'https://x/clip.mp4'},
      );
      final api = _apiWith(adapter);

      await api.uploadMedia(
        mediaBytes: Uint8List.fromList([1, 2, 3]),
        mediaFilename: 'clip.mp4',
        idempotencyKey: 'upload-1',
        muted: false,
      );

      expect(
        adapter.lastRequestBody,
        contains('content-disposition: form-data; name="muted"'),
      );
      expect(adapter.lastRequestBody, contains('\r\nfalse\r\n'));
    });

    test('413 maps to UpdateMediaTooLargeException', () async {
      final api = _apiWith(
        _FakeAdapter(statusCode: 413, bodyJson: {'error': 'file too large'}),
      );

      await expectLater(
        api.uploadMedia(
          mediaBytes: Uint8List.fromList([1]),
          mediaFilename: 'photo.jpg',
          idempotencyKey: 'upload-1',
          muted: true,
        ),
        throwsA(isA<UpdateMediaTooLargeException>()),
      );
    });

    test('415 maps to UpdateMediaUnsupportedException', () async {
      final api = _apiWith(
        _FakeAdapter(
          statusCode: 415,
          bodyJson: {'error': 'unsupported media type'},
        ),
      );

      await expectLater(
        api.uploadMedia(
          mediaBytes: Uint8List.fromList([1]),
          mediaFilename: 'photo.jpg',
          idempotencyKey: 'upload-1',
          muted: true,
        ),
        throwsA(isA<UpdateMediaUnsupportedException>()),
      );
    });
  });
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

class _EmptyBodyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '',
      201,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
