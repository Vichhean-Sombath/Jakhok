import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/otp_verification_screen.dart';
import 'services/firebase_auth_service.dart';
import 'services/auth_otp_api.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.load();
  FirebaseAuthService? authService;
  String? firebaseSetupError;
  final options = FirebaseAuthService.optionsFromEnvironment();
  if (options != null) {
    try {
      await Firebase.initializeApp(options: options);
      authService = FirebaseAuthService(FirebaseAuth.instance);
    } catch (error) {
      firebaseSetupError = error.toString();
    }
  }
  runApp(
    ScannerApp(
      state: state,
      authService: authService,
      firebaseSetupError: firebaseSetupError,
    ),
  );
}

class ScannerApp extends StatelessWidget {
  const ScannerApp({
    super.key,
    required this.state,
    this.authService,
    this.firebaseSetupError,
  });
  final AppState state;
  final FirebaseAuthService? authService;
  final String? firebaseSetupError;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => MaterialApp(
      title: 'Netra',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: state.isDark ? ThemeMode.dark : ThemeMode.light,
      home: authService == null
          ? SignInScreen(setupError: firebaseSetupError)
          : _AuthRouter(state: state, authService: authService!),
    ),
  );
}

class _AuthRouter extends StatefulWidget {
  const _AuthRouter({required this.state, required this.authService});

  final AppState state;
  final FirebaseAuthService authService;

  @override
  State<_AuthRouter> createState() => _AuthRouterState();
}

class _AuthRouterState extends State<_AuthRouter> {
  final _otpApi = AuthOtpApi();
  StreamSubscription<User?>? _authSubscription;
  User? _user;
  Future<bool>? _sessionCheck;

  @override
  void initState() {
    super.initState();
    _user = widget.authService.auth.currentUser;
    if (_user != null) _sessionCheck = _checkSession(_user!);
    _authSubscription = widget.authService.auth.idTokenChanges().listen((user) {
      if (!mounted) return;
      setState(() {
        _user = user;
        _sessionCheck = user == null ? null : _checkSession(user);
      });
    });
  }

  Future<bool> _checkSession(User user) async {
    final token = await user.getIdToken();
    if (token == null) return false;
    return _otpApi.sessionVerified(token);
  }

  Future<void> _signOut(BuildContext context) async {
    try {
      await widget.authService.signOut();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not sign out. Please try again.'),
          ),
        );
      }
    }
  }

  void _refreshSessionStatus() {
    final user = _user;
    setState(() {
      _sessionCheck = user == null ? null : _checkSession(user);
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _otpApi.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    if (user == null) return SignInScreen(authService: widget.authService);
    final sessionCheck = _sessionCheck ??= _checkSession(user);
    return FutureBuilder<bool>(
      future: sessionCheck,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoadingScreen();
        }
        if (snapshot.hasError) {
          return _AuthSessionErrorScreen(
            onRetry: () => setState(() => _sessionCheck = _checkSession(user)),
            onSignOut: () => _signOut(context),
          );
        }
        if (!snapshot.hasData) return const _AuthLoadingScreen();
        if (snapshot.data!) {
          return HomeScreen(
            state: widget.state,
            authService: widget.authService,
            user: user,
          );
        }
        return OtpVerificationScreen(
          key: ValueKey('${user.uid}:${user.metadata.lastSignInTime}'),
          user: user,
          onVerified: _refreshSessionStatus,
        );
      },
    );
  }
}

class _AuthSessionErrorScreen extends StatelessWidget {
  const _AuthSessionErrorScreen({
    required this.onRetry,
    required this.onSignOut,
  });

  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.cloud_off_rounded,
                    size: 40,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Could not check your sign-in',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'We could not confirm your verification status. Check your connection and try again, or sign out.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry session check'),
                  ),
                  TextButton.icon(
                    onPressed: onSignOut,
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
