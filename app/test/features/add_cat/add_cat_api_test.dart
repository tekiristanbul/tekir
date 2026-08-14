import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/network/api_client.dart';
import 'package:app/features/add_cat/data/add_cat_api.dart';

// Mirrors follows_api_test.dart's _FakeAdapter/_ThrowingAdapter exactly.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.statusCode, this.bodyJson});

  final int statusCode;
  final dynamic bodyJson;
  RequestOptions? lastOptions;
  Object? lastData;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    lastData = options.data;
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

AddCatApi _apiWith(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  return AddCatApi(ApiClient(dio: dio));
}

final _createdCatResponse = {
  'cat': {
    'id': 'cat-new',
    'name': 'Boncuk',
    'area': {'lat': 41.03, 'lng': 28.98},
    'area_label': null,
    'primary_photo': '/v1/media/objects/x.jpg',
    'created_at': '2026-01-01T12:00:00Z',
    'last_update_at': null,
    'active_alert': null,
  },
};

void main() {
  group('AddCatApi.fetchNearby', () {
    test('gets the correct path/query and parses candidates', () async {
      final adapter = _FakeAdapter(
        statusCode: 200,
        bodyJson: [
          {'id': 'cat-1', 'name': 'tekir', 'primary_photo': 'https://x/1.jpg'},
        ],
      );
      final api = _apiWith(adapter);

      final candidates = await api.fetchNearby(lat: 41.03, lng: 28.98);

      expect(adapter.lastOptions?.path, '/v1/cats/nearby');
      expect(adapter.lastOptions?.method, 'GET');
      expect(adapter.lastOptions?.queryParameters, {
        'lat': 41.03,
        'lng': 28.98,
        'radius': 50,
      });
      expect(candidates, hasLength(1));
      expect(candidates.first.id, 'cat-1');
      expect(candidates.first.name, 'tekir');
    });

    test('an empty list is a valid empty result', () async {
      final api = _apiWith(
        _FakeAdapter(statusCode: 200, bodyJson: <dynamic>[]),
      );
      final candidates = await api.fetchNearby(lat: 41.03, lng: 28.98);
      expect(candidates, isEmpty);
    });

    test('a connection failure maps to AddCatNetworkException', () async {
      final api = _apiWith(_ThrowingAdapter());
      await expectLater(
        api.fetchNearby(lat: 41.03, lng: 28.98),
        throwsA(isA<AddCatNetworkException>()),
      );
    });
  });

  group('AddCatApi.createCat', () {
    test('posts multipart form data to the correct path', () async {
      final adapter = _FakeAdapter(
        statusCode: 201,
        bodyJson: _createdCatResponse,
      );
      final api = _apiWith(adapter);

      final cat = await api.createCat(
        lat: 41.03,
        lng: 28.98,
        name: 'Boncuk',
        confirmedNew: true,
        photoBytes: Uint8List.fromList([1, 2, 3]),
        photoFilename: 'cat.jpg',
        idempotencyKey: 'key-1',
      );

      expect(adapter.lastOptions?.path, '/v1/cats');
      expect(adapter.lastOptions?.method, 'POST');
      expect(adapter.lastData, isA<FormData>());
      final form = adapter.lastData! as FormData;
      expect(form.fields.firstWhere((f) => f.key == 'lat').value, '41.03');
      expect(form.fields.firstWhere((f) => f.key == 'lng').value, '28.98');
      expect(
        form.fields.firstWhere((f) => f.key == 'confirmed_new').value,
        'true',
      );
      expect(form.files.single.key, 'photo');
      expect(adapter.lastOptions?.headers['Idempotency-Key'], 'key-1');
      expect(cat.id, 'cat-new');
    });

    test('omits the name field when none is given', () async {
      final adapter = _FakeAdapter(
        statusCode: 201,
        bodyJson: _createdCatResponse,
      );
      final api = _apiWith(adapter);

      await api.createCat(
        lat: 41.03,
        lng: 28.98,
        confirmedNew: false,
        photoBytes: Uint8List.fromList([1]),
        photoFilename: 'cat.jpg',
        idempotencyKey: 'key-1',
      );

      final form = adapter.lastData! as FormData;
      expect(form.fields.where((f) => f.key == 'name'), isEmpty);
    });

    test(
      'omits confirmed_new entirely when false, per the api contract (never "false")',
      () async {
        final adapter = _FakeAdapter(
          statusCode: 201,
          bodyJson: _createdCatResponse,
        );
        final api = _apiWith(adapter);

        await api.createCat(
          lat: 41.03,
          lng: 28.98,
          confirmedNew: false,
          photoBytes: Uint8List.fromList([1]),
          photoFilename: 'cat.jpg',
          idempotencyKey: 'key-1',
        );

        final form = adapter.lastData! as FormData;
        expect(form.fields.where((f) => f.key == 'confirmed_new'), isEmpty);
      },
    );

    test(
      '409 maps to AddCatDuplicateCandidatesException with candidates',
      () async {
        final api = _apiWith(
          _FakeAdapter(
            statusCode: 409,
            bodyJson: {
              'candidates': [
                {
                  'id': 'cat-1',
                  'name': 'tekir',
                  'primary_photo': 'https://x/1.jpg',
                },
              ],
            },
          ),
        );

        await expectLater(
          api.createCat(
            lat: 41.03,
            lng: 28.98,
            confirmedNew: false,
            photoBytes: Uint8List.fromList([1]),
            photoFilename: 'cat.jpg',
            idempotencyKey: 'key-1',
          ),
          throwsA(
            isA<AddCatDuplicateCandidatesException>().having(
              (e) => e.candidates.first.id,
              'candidates.first.id',
              'cat-1',
            ),
          ),
        );
      },
    );

    test('401 maps to AddCatUnauthorizedException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 401));
      await expectLater(
        api.createCat(
          lat: 41.03,
          lng: 28.98,
          confirmedNew: true,
          photoBytes: Uint8List.fromList([1]),
          photoFilename: 'cat.jpg',
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<AddCatUnauthorizedException>()),
      );
    });

    test('413 maps to AddCatMediaTooLargeException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 413));
      await expectLater(
        api.createCat(
          lat: 41.03,
          lng: 28.98,
          confirmedNew: true,
          photoBytes: Uint8List.fromList([1]),
          photoFilename: 'cat.jpg',
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<AddCatMediaTooLargeException>()),
      );
    });

    test('415 maps to AddCatUnsupportedMediaException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 415));
      await expectLater(
        api.createCat(
          lat: 41.03,
          lng: 28.98,
          confirmedNew: true,
          photoBytes: Uint8List.fromList([1]),
          photoFilename: 'cat.jpg',
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<AddCatUnsupportedMediaException>()),
      );
    });

    // issue #241: the pre-publication content check rejected the name or
    // photo — distinct from the generic 500 a classifier failure surfaces
    // as (unchanged, still AddCatServerException below).
    test('422 maps to AddCatContentRejectedException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 422));
      await expectLater(
        api.createCat(
          lat: 41.03,
          lng: 28.98,
          confirmedNew: true,
          photoBytes: Uint8List.fromList([1]),
          photoFilename: 'cat.jpg',
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<AddCatContentRejectedException>()),
      );
    });

    test('a connection failure maps to AddCatNetworkException', () async {
      final api = _apiWith(_ThrowingAdapter());
      await expectLater(
        api.createCat(
          lat: 41.03,
          lng: 28.98,
          confirmedNew: true,
          photoBytes: Uint8List.fromList([1]),
          photoFilename: 'cat.jpg',
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<AddCatNetworkException>()),
      );
    });

    test('500 maps to AddCatServerException', () async {
      final api = _apiWith(_FakeAdapter(statusCode: 500));
      await expectLater(
        api.createCat(
          lat: 41.03,
          lng: 28.98,
          confirmedNew: true,
          photoBytes: Uint8List.fromList([1]),
          photoFilename: 'cat.jpg',
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<AddCatServerException>()),
      );
    });
  });
}
