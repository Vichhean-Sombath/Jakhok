import 'dart:convert';

import 'package:http/http.dart' as http;

class AuthOtpApiException implements Exception {
  const AuthOtpApiException(
    this.message, {
    this.statusCode,
    this.retryAfterSeconds,
  });

  final String message;
  final int? statusCode;
  final int? retryAfterSeconds;

  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => message;
}

sealed class AuthOtpStartResponse {
  const AuthOtpStartResponse();

  factory AuthOtpStartResponse.fromJson(
    Map<String, dynamic> json, {
    required bool emailStart,
  }) {
    final verified = json['verified'];
    if (verified == true) {
      if (json.containsKey('challengeId') ||
          json.containsKey('expiresInSeconds')) {
        throw const AuthOtpApiException(
          'The auth server returned an invalid response.',
        );
      }
      final customToken = json['customToken'];
      if (emailStart) {
        if (customToken is! String || customToken.trim().isEmpty) {
          throw const AuthOtpApiException(
            'The auth server returned an invalid response.',
          );
        }
        return AuthOtpVerified(customToken: customToken.trim());
      }
      if (json.containsKey('customToken')) {
        throw const AuthOtpApiException(
          'The auth server returned an invalid response.',
        );
      }
      return const AuthOtpVerified();
    }

    if (json.containsKey('verified') || json.containsKey('customToken')) {
      throw const AuthOtpApiException(
        'The auth server returned an invalid response.',
      );
    }
    final id = json['challengeId'];
    final expires = json['expiresInSeconds'];
    if (id is! String ||
        id.trim().isEmpty ||
        expires is! num ||
        !expires.isFinite ||
        expires <= 0) {
      throw const AuthOtpApiException(
        'The auth server returned an invalid response.',
      );
    }
    return AuthOtpChallenge(id: id.trim(), expiresInSeconds: expires.toInt());
  }
}

class AuthOtpChallenge extends AuthOtpStartResponse {
  const AuthOtpChallenge({required this.id, required this.expiresInSeconds});

  final String id;
  final int expiresInSeconds;
}

class AuthOtpVerified extends AuthOtpStartResponse {
  const AuthOtpVerified({this.customToken});

  /// Present only for the password-verified local-admin email start response.
  final String? customToken;
}

class AuthOtpApi {
  AuthOtpApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl =
          (baseUrl ??
                  const String.fromEnvironment(
                    'AUTH_API_BASE_URL',
                    defaultValue: 'https://auth.neuroshift.dev',
                  ))
              .trim()
              .replaceFirst(RegExp(r'/+$'), '');

  final http.Client _client;
  final String baseUrl;

  Future<AuthOtpStartResponse> startEmail({
    required String email,
    required String password,
    required bool register,
  }) async {
    final response = await _post('/api/auth/email/start', {
      'email': email.trim(),
      'password': password,
      'mode': register ? 'register' : 'login',
    });
    return AuthOtpStartResponse.fromJson(response, emailStart: true);
  }

  Future<AuthOtpStartResponse> startForSignedInUser(String idToken) async {
    final response = await _post('/api/auth/otp/start', {'idToken': idToken});
    return AuthOtpStartResponse.fromJson(response, emailStart: false);
  }

  Future<String?> verifyCode({
    required String challengeId,
    required String code,
    String? idToken,
  }) async {
    final response = await _post('/api/auth/otp/verify', {
      'challengeId': challengeId,
      'code': code,
      if (idToken != null) 'idToken': idToken,
    });
    return response['customToken'] as String?;
  }

  Future<bool> sessionVerified(String idToken) async {
    final response = await _post('/api/auth/session/status', {
      'idToken': idToken,
    });
    return response['verified'] == true;
  }

  Future<void> completeSession(String idToken) async {
    await _post('/api/auth/session/complete', {'idToken': idToken});
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    if (baseUrl.isEmpty) {
      throw const AuthOtpApiException(
        'OTP sign-in is not configured yet. Add AUTH_API_BASE_URL to this build.',
      );
    }
    final uri = Uri.tryParse('$baseUrl$path');
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw const AuthOtpApiException('The auth API address is invalid.');
    }
    try {
      final response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      Map<String, dynamic> json = {};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) json = decoded;
      } on FormatException {
        // Preserve the HTTP status for error responses even when an older
        // server sends an empty or non-JSON body.
        if (response.statusCode >= 200 && response.statusCode < 300) {
          rethrow;
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = json['error'];
        throw AuthOtpApiException(
          error is String && error.trim().isNotEmpty
              ? error
              : 'Could not contact the auth service.',
          statusCode: response.statusCode,
          retryAfterSeconds: _parseRetryAfterSeconds(
            json['retryAfterSeconds'],
          ),
        );
      }
      return json;
    } on AuthOtpApiException {
      rethrow;
    } catch (_) {
      throw const AuthOtpApiException(
        'Could not reach the auth service. Check your connection and try again.',
      );
    }
  }

  int? _parseRetryAfterSeconds(Object? value) {
    if (value is int && value > 0) return value;
    return null;
  }

  void close() => _client.close();
}
