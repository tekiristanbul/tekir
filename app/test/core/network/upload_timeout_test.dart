import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/network/api_client.dart';
import 'package:app/features/add_cat/data/add_cat_api.dart';

/// Answers only after [delay], so a request that gives up early gives up here.
class _SlowAdapter implements HttpClientAdapter {
  _SlowAdapter(this.delay, this.body);

  final Duration delay;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await Future<void>.delayed(delay);
    return ResponseBody.fromString(
      body,
      201,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  // Creating a cat keeps the connection open while the backend decodes the
  // photo, normalizes its orientation, re-encodes it, stores it, and (once
  // moderation ships) has it classified. At the previous shared 5s budget
  // production logged this failing at 5.1s with the client already gone,
  // while a successful create took 3.3s — a coin flip decided by photo size
  // and signal strength.
  test(
    'creating a cat outlives a slow backend response',
    () async {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'http://localhost:8080',
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      dio.httpClientAdapter = _SlowAdapter(
        const Duration(seconds: 7),
        '{"cat":{"id":"c1","name":"tekir","area":{"lat":41.0,"lng":29.0},'
        '"created_at":"2026-01-01T00:00:00Z"}}',
      );

      final api = AddCatApi(ApiClient(dio: dio));
      final detail = await api.createCat(
        lat: 41.0,
        lng: 29.0,
        confirmedNew: true,
        photoBytes: Uint8List.fromList([1, 2, 3]),
        photoFilename: 'cat.jpg',
        idempotencyKey: 'key-1',
      );

      expect(detail.id, 'c1');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('the media upload budget is well clear of a plain read budget', () {
    expect(
      ApiClient.mediaUploadTimeout,
      greaterThan(const Duration(seconds: 30)),
    );
  });
}
