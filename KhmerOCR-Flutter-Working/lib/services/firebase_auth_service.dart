import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

class FirebaseAuthService {
  FirebaseAuthService(this.auth);

  final FirebaseAuth auth;
  bool _googleSignInInitialized = false;

  // These are Firebase client settings for netra-ocr, which are included in
  // the Flutter web bundle by design. Never place Firebase Admin credentials
  // or service-account private keys here.
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _webAppId = String.fromEnvironment('FIREBASE_WEB_APP_ID');
  static const _androidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
  );
  static const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const _authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );
  static const _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');
  static const _googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );

  static FirebaseOptions? optionsFromEnvironment() {
    final appId = kIsWeb
        ? (_webAppId.isEmpty
              ? const String.fromEnvironment('FIREBASE_APP_ID')
              : _webAppId)
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => _androidAppId,
            TargetPlatform.iOS || TargetPlatform.macOS => _iosAppId,
            _ => '',
          };
    if (_apiKey.isEmpty ||
        _projectId.isEmpty ||
        _senderId.isEmpty ||
        appId.isEmpty) {
      return null;
    }

    return FirebaseOptions(
      apiKey: _apiKey,
      appId: appId,
      messagingSenderId: _senderId,
      projectId: _projectId,
      authDomain: kIsWeb
          ? (_authDomain.isEmpty ? '$_projectId.firebaseapp.com' : _authDomain)
          : null,
      storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
      iosBundleId:
          !kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.macOS) &&
              _iosBundleId.isNotEmpty
          ? _iosBundleId
          : null,
    );
  }

  Future<UserCredential> signInWithGoogle() async {
    if (kIsWeb) {
      return auth.signInWithPopup(GoogleAuthProvider());
    }

    final googleSignIn = GoogleSignIn.instance;
    if (!_googleSignInInitialized) {
      await googleSignIn.initialize(
        serverClientId: _googleServerClientId.isEmpty
            ? null
            : _googleServerClientId,
      );
      _googleSignInInitialized = true;
    }

    if (!googleSignIn.supportsAuthenticate()) {
      throw UnsupportedError('Google sign-in is not supported on this device.');
    }

    final googleUser = await googleSignIn.authenticate();
    final idToken = googleUser.authentication.idToken;
    if (idToken == null) {
      throw FirebaseAuthException(
        code: 'missing-google-id-token',
        message: 'Google did not return an ID token. Check the OAuth setup.',
      );
    }

    final credential = GoogleAuthProvider.credential(idToken: idToken);
    return auth.signInWithCredential(credential);
  }

  Future<void> sendPasswordResetEmail({required String email}) {
    return auth.sendPasswordResetEmail(email: email.trim());
  }

  Future<void> signOut() async {
    await auth.signOut();
    if (!kIsWeb && _googleSignInInitialized) {
      await GoogleSignIn.instance.signOut();
    }
  }
}
