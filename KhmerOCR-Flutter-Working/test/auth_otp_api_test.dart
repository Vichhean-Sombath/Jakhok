import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:khmer_ocr_flutter/services/auth_otp_api.dart';

void main() {
  test('email start accepts the local-admin custom-token response', () async {
    final api = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/email/start');
        return http.Response(
          jsonEncode({'verified': true, 'customToken': 'firebase-custom-token'}),
          200,
        );
      }),
    );

    final response = await api.startEmail(
      email: 'admin@example.test',
      password: 'password',
      register: false,
    );

    expect(response, isA<AuthOtpVerified>());
    expect((response as AuthOtpVerified).customToken, 'firebase-custom-token');
    api.close();
  });

  test('email start accepts a standard OTP challenge response', () async {
    final api = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/email/start');
        return http.Response(
          jsonEncode({'challengeId': 'email-challenge', 'expiresInSeconds': 300}),
          200,
        );
      }),
    );

    final response = await api.startEmail(
      email: 'user@example.test',
      password: 'password',
      register: false,
    );

    expect(response, isA<AuthOtpChallenge>());
    final emailChallenge = response as AuthOtpChallenge;
    expect(emailChallenge.id, 'email-challenge');
    expect(emailChallenge.expiresInSeconds, 300);
    api.close();
  });

  test('OTP start accepts verified admin status without a token', () async {
    final api = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/otp/start');
        return http.Response(jsonEncode({'verified': true}), 200);
      }),
    );

    final response = await api.startForSignedInUser('firebase-id-token');

    expect(response, isA<AuthOtpVerified>());
    expect((response as AuthOtpVerified).customToken, isNull);
    api.close();
  });

  test('OTP start accepts a standard OTP challenge response', () async {
    final api = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/otp/start');
        return http.Response(
          jsonEncode({'challengeId': 'google-challenge', 'expiresInSeconds': 240}),
          200,
        );
      }),
    );

    final response = await api.startForSignedInUser('firebase-id-token');

    expect(response, isA<AuthOtpChallenge>());
    final googleChallenge = response as AuthOtpChallenge;
    expect(googleChallenge.id, 'google-challenge');
    expect(googleChallenge.expiresInSeconds, 240);
    api.close();
  });

  test('rejects malformed verified responses for each start endpoint', () async {
    final emailApi = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient(
        (_) async => http.Response(jsonEncode({'verified': true}), 200),
      ),
    );
    final otpApi = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'verified': true, 'customToken': 'unexpected-token'}),
          200,
        ),
      ),
    );

    await expectLater(
      emailApi.startEmail(
        email: 'admin@example.test',
        password: 'password',
        register: false,
      ),
      throwsA(isA<AuthOtpApiException>()),
    );
    await expectLater(
      otpApi.startForSignedInUser('firebase-id-token'),
      throwsA(isA<AuthOtpApiException>()),
    );
    emailApi.close();
    otpApi.close();
  });

  test('rejects malformed challenge payloads', () async {
    final api = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'challengeId': '  ', 'expiresInSeconds': 300}),
          200,
        ),
      ),
    );

    await expectLater(
      api.startForSignedInUser('firebase-id-token'),
      throwsA(isA<AuthOtpApiException>()),
    );
    api.close();
  });

  test('retains typed retry duration from a rate-limit response', () async {
    final api = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'Try again later.', 'retryAfterSeconds': 125}),
          429,
        ),
      ),
    );

    await expectLater(
      api.startForSignedInUser('token'),
      throwsA(
        isA<AuthOtpApiException>()
            .having((error) => error.statusCode, 'statusCode', 429)
            .having((error) => error.isRateLimited, 'isRateLimited', isTrue)
            .having((error) => error.retryAfterSeconds, 'retryAfterSeconds', 125)
            .having((error) => error.message, 'message', 'Try again later.'),
      ),
    );
    api.close();
  });

  test('invalid or absent retry duration stays null on a 429', () async {
    final api = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'Rate limited.', 'retryAfterSeconds': '120'}),
          429,
        ),
      ),
    );

    await expectLater(
      api.startForSignedInUser('token'),
      throwsA(
        isA<AuthOtpApiException>()
            .having((error) => error.statusCode, 'statusCode', 429)
            .having((error) => error.isRateLimited, 'isRateLimited', isTrue)
            .having((error) => error.retryAfterSeconds, 'retryAfterSeconds', isNull),
      ),
    );
    api.close();
  });

  test('preserves status for an older non-JSON rate-limit response', () async {
    final api = AuthOtpApi(
      baseUrl: 'https://auth.example',
      client: MockClient((_) async => http.Response('Too many requests', 429)),
    );

    await expectLater(
      api.startForSignedInUser('token'),
      throwsA(
        isA<AuthOtpApiException>()
            .having((error) => error.statusCode, 'statusCode', 429)
            .having((error) => error.isRateLimited, 'isRateLimited', isTrue)
            .having((error) => error.retryAfterSeconds, 'retryAfterSeconds', isNull),
      ),
    );
    api.close();
  });
}
