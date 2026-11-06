import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/firebase_auth_service.dart';
import '../services/auth_otp_api.dart';
import '../widgets/app_ui.dart';
import '../theme.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.authService, this.setupError});

  final FirebaseAuthService? authService;
  final String? setupError;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = TextEditingController();
  final _otpApi = AuthOtpApi();
  String? _emailChallengeId;
  Timer? _emailResendTimer;
  Timer? _emailExpiryTimer;
  int _emailResendIn = 0;
  int _emailExpiresIn = 0;
  bool _signingIn = false;
  bool _creatingAccount = false;
  bool _emailSendFailed = false;
  bool _emailRateLimitHint = false;
  bool _hidePassword = true;
  String? _busyAction;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _emailResendTimer?.cancel();
    _emailExpiryTimer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    _otpApi.close();
    super.dispose();
  }

  Future<void> _signIn() async {
    final authService = widget.authService;
    if (authService == null) {
      setState(() {
        _error = widget.setupError == null
            ? 'Firebase is not configured yet. Add this app to your Firebase project and enable Google or Email/Password sign-in.'
            : 'Firebase could not start. Check the Firebase setup and try again.';
      });
      return;
    }

    setState(() {
      _signingIn = true;
      _busyAction = 'google';
      _error = null;
      _notice = null;
    });
    try {
      await authService.signInWithGoogle();
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() => _error = _authErrorMessage(error, provider: 'Google'));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _authErrorMessage(error, provider: 'Google'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _signingIn = false;
          _busyAction = null;
        });
      }
    }
  }

  Future<void> _submitEmailPassword() async {
    if (_emailChallengeId == null && _emailResendIn > 0) return;
    if (_emailChallengeId != null) {
      await _verifyEmailOtp();
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final authService = widget.authService;
    if (authService == null) {
      setState(() {
        _error = 'Firebase setup is required before you can sign in.';
        _notice = null;
      });
      return;
    }

    setState(() {
      _signingIn = true;
      _busyAction = _creatingAccount ? 'signup' : 'email';
      _error = null;
      _notice = null;
      _emailRateLimitHint = false;
    });
    try {
      final response = await _otpApi.startEmail(
        email: _emailController.text,
        password: _passwordController.text,
        register: _creatingAccount,
      );
      if (response is AuthOtpVerified) {
        final customToken = response.customToken;
        if (customToken == null) {
          throw const AuthOtpApiException(
            'The auth server returned an invalid response.',
          );
        }
        await _signInWithLocalAdminToken(customToken);
        return;
      }
      final challenge = response as AuthOtpChallenge;
      if (mounted) {
        setState(() {
          _emailChallengeId = challenge.id;
          _emailSendFailed = false;
          _emailRateLimitHint = false;
          _otpController.clear();
          _notice = _creatingAccount
              ? 'We sent a verification code to ${_emailController.text.trim()}.'
              : 'We sent a sign-in code to ${_emailController.text.trim()}.';
        });
        _startEmailTimers(challenge.expiresInSeconds);
      }
    } on AuthOtpApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _emailSendFailed = _emailChallengeId == null;
          _emailRateLimitHint = error.isRateLimited;
        });
        if (error.isRateLimited ||
            error.message.toLowerCase().contains('wait before requesting')) {
          _startEmailResendCooldown(
            error.isRateLimited ? error.retryAfterSeconds ?? 60 : 60,
          );
        }
      }
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() => _error = _authErrorMessage(error, provider: 'email'));
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not sign in. Try again.');
    } finally {
      if (mounted) {
        setState(() {
          _signingIn = false;
          _busyAction = null;
        });
      }
    }
  }

  Future<void> _signInWithLocalAdminToken(String customToken) async {
    final authService = widget.authService;
    if (authService == null) {
      throw const AuthOtpApiException(
        'Firebase setup is required before you can sign in.',
      );
    }
    final credential = await authService.auth.signInWithCustomToken(
      customToken,
    );
    final idToken = await credential.user?.getIdToken();
    if (idToken == null) {
      throw const AuthOtpApiException('Could not finish Firebase sign-in.');
    }
    // Do not complete an OTP session here. The auth router checks the current
    // server-side session status, including the current admin claim.
  }

  Future<void> _verifyEmailOtp() async {
    final challengeId = _emailChallengeId;
    final authService = widget.authService;
    final code = _otpController.text.trim();
    if (challengeId == null) return;
    if (_emailExpiresIn <= 0) {
      setState(() {
        _error = 'This code has expired. Request a new code to continue.';
        _notice = null;
      });
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() {
        _error = 'Enter the 6-digit code from your email.';
        _notice = null;
      });
      return;
    }
    if (authService == null) {
      setState(() {
        _error = 'Firebase setup is required before you can finish signing in.';
        _notice = null;
      });
      return;
    }

    setState(() {
      _signingIn = true;
      _busyAction = 'verify';
      _error = null;
      _notice = null;
    });
    try {
      final customToken = await _otpApi.verifyCode(
        challengeId: challengeId,
        code: code,
      );
      if (customToken == null) {
        throw const AuthOtpApiException(
          'The auth server did not return a sign-in token.',
        );
      }
      final credential = await authService.auth.signInWithCustomToken(
        customToken,
      );
      final idToken = await credential.user?.getIdToken();
      if (idToken == null) {
        throw const AuthOtpApiException('Could not finish Firebase sign-in.');
      }
      await _otpApi.completeSession(idToken);
    } on AuthOtpApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() => _error = _authErrorMessage(error, provider: 'email'));
      }
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Could not verify this code. Try again.');
    } finally {
      if (mounted) {
        setState(() {
          _signingIn = false;
          _busyAction = null;
        });
      }
    }
  }

  Future<void> _resendEmailOtp() async {
    if (_emailResendIn > 0 || _signingIn || _emailChallengeId == null) return;
    setState(() {
      _signingIn = true;
      _busyAction = 'resend';
      _error = null;
      _notice = null;
      _emailRateLimitHint = false;
    });
    try {
      final response = await _otpApi.startEmail(
        email: _emailController.text,
        password: _passwordController.text,
        register: _creatingAccount,
      );
      if (response is AuthOtpVerified) {
        final customToken = response.customToken;
        if (customToken == null) {
          throw const AuthOtpApiException(
            'The auth server returned an invalid response.',
          );
        }
        await _signInWithLocalAdminToken(customToken);
        return;
      }
      final challenge = response as AuthOtpChallenge;
      if (mounted) {
        setState(() {
          _emailChallengeId = challenge.id;
          _emailSendFailed = false;
          _emailRateLimitHint = false;
          _otpController.clear();
          _notice = 'A new code was sent to ${_emailController.text.trim()}.';
        });
        _startEmailTimers(challenge.expiresInSeconds);
      }
    } on AuthOtpApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _emailRateLimitHint = error.isRateLimited;
        });
        _startEmailResendCooldown(
          error.isRateLimited ? error.retryAfterSeconds ?? 60 : 60,
        );
      }
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() => _error = _authErrorMessage(error, provider: 'email'));
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not sign in. Try again.');
    } finally {
      if (mounted) {
        setState(() {
          _signingIn = false;
          _busyAction = null;
        });
      }
    }
  }

  void _useDifferentEmail() => setState(() {
    _emailResendTimer?.cancel();
    _emailExpiryTimer?.cancel();
    _emailChallengeId = null;
    _emailSendFailed = false;
    _emailRateLimitHint = false;
    _emailResendIn = 0;
    _emailExpiresIn = 0;
    _otpController.clear();
    _error = null;
    _notice = null;
  });

  void _startEmailTimers(int expiresInSeconds) {
    _emailExpiryTimer?.cancel();
    _startEmailResendCooldown();
    setState(
      () => _emailExpiresIn = expiresInSeconds < 0 ? 0 : expiresInSeconds,
    );
    _emailExpiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      if (_emailExpiresIn <= 1) {
        timer.cancel();
        setState(() => _emailExpiresIn = 0);
      } else {
        setState(() => _emailExpiresIn--);
      }
    });
  }

  void _startEmailResendCooldown([int seconds = 60]) {
    _emailResendTimer?.cancel();
    setState(() => _emailResendIn = seconds < 1 ? 60 : seconds);
    _emailResendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      if (_emailResendIn <= 1) {
        timer.cancel();
        setState(() => _emailResendIn = 0);
      } else {
        setState(() => _emailResendIn--);
      }
    });
  }

  String _formatCountdown(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _error = 'Enter your email address first, then tap Forgot password.';
        _notice = null;
      });
      return;
    }
    final authService = widget.authService;
    if (authService == null) {
      setState(() {
        _error = 'Firebase setup is required before you can reset a password.';
        _notice = null;
      });
      return;
    }

    setState(() {
      _signingIn = true;
      _busyAction = 'reset';
      _error = null;
      _notice = null;
    });
    try {
      await authService.sendPasswordResetEmail(email: email);
      if (mounted) {
        setState(
          () => _notice =
              'If an account exists for that email, a reset link has been sent.',
        );
      }
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() => _error = _authErrorMessage(error, provider: 'email'));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _authErrorMessage(error, provider: 'email'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _signingIn = false;
          _busyAction = null;
        });
      }
    }
  }

  String _authErrorMessage(Object error, {required String provider}) {
    if (error is FirebaseAuthException) {
      return switch (error.code) {
        'popup-closed-by-user' || 'cancelled' => 'Sign-in was cancelled.',
        'account-exists-with-different-credential' =>
          'An account already exists with a different sign-in method.',
        'unauthorized-domain' =>
          'This website domain is not authorized in Firebase Authentication.',
        'operation-not-allowed' =>
          '$provider sign-in is not enabled in Firebase Authentication.',
        'invalid-email' => 'Enter a valid email address.',
        'user-not-found' => 'No account was found for that email address.',
        'wrong-password' ||
        'invalid-credential' => 'The email or password is incorrect.',
        'email-already-in-use' =>
          'An account already uses that email. Try signing in instead.',
        'weak-password' =>
          'Choose a stronger password (at least 6 characters).',
        'too-many-requests' =>
          'There have been too many attempts. Wait a moment and try again.',
        _ => error.message ?? 'Could not sign in. Please try again.',
      };
    }
    return 'Could not sign in. Check your connection and Firebase configuration, then try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final muted = theme.colorScheme.onSurfaceVariant;
    final cardColor = dark ? const Color(0xFF111823) : const Color(0xFFF8FAFC);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 56,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1060),
                  child: Row(
                    children: [
                      if (constraints.maxWidth >= 900) ...[
                        const Expanded(child: _SignInIntro()),
                        const SizedBox(width: 64),
                      ],
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    const _BrandMark(),
                                    const SizedBox(width: 12),
                                    Text(
                                      'Netra',
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -.3,
                                          ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      'KHMER OCR',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: muted,
                                            letterSpacing: 1.1,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 30),
                                Text(
                                  _emailChallengeId != null
                                      ? 'Check your email'
                                      : _creatingAccount
                                      ? 'Create your account'
                                      : 'Welcome back',
                                  textAlign: TextAlign.start,
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -.6,
                                        height: 1.2,
                                      ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _emailChallengeId != null
                                      ? 'Enter the 6-digit code we sent to your email.'
                                      : _creatingAccount
                                      ? 'Create an account with Google or use email and password. Email signup includes a verification code.'
                                      : 'Continue with Google or sign in with email and password plus a verification code.',
                                  textAlign: TextAlign.start,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: muted,
                                    height: 1.55,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Container(
                                  padding: const EdgeInsets.all(20),
                                  decoration: BoxDecoration(
                                    color: cardColor,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: theme.dividerColor,
                                    ),
                                    boxShadow: dark
                                        ? const []
                                        : [
                                            BoxShadow(
                                              color: Colors.black.withValues(
                                                alpha: .035,
                                              ),
                                              blurRadius: 24,
                                              offset: const Offset(0, 10),
                                            ),
                                          ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (_emailChallengeId == null) ...[
                                        FilledButton.tonal(
                                          onPressed: _signingIn
                                              ? null
                                              : _signIn,
                                          style: FilledButton.styleFrom(
                                            backgroundColor: dark
                                                ? const Color(0xFF151D29)
                                                : Colors.white,
                                            foregroundColor:
                                                theme.colorScheme.onSurface,
                                            minimumSize: const Size.fromHeight(
                                              50,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              side: BorderSide(
                                                color: theme.dividerColor,
                                              ),
                                            ),
                                          ),
                                          child: _busyAction == 'google'
                                              ? const _ButtonProgressLabel(
                                                  label:
                                                      'Connecting to Google…',
                                                )
                                              : const Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    _GoogleMark(),
                                                    SizedBox(width: 12),
                                                    Flexible(
                                                      child: Text(
                                                        'Continue with Google',
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                        ),
                                        const SizedBox(height: 20),
                                        Row(
                                          children: [
                                            const Expanded(child: Divider()),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                  ),
                                              child: Text(
                                                'OR USE EMAIL',
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: muted,
                                                      letterSpacing: 1,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ),
                                            const Expanded(child: Divider()),
                                          ],
                                        ),
                                        const SizedBox(height: 18),
                                        SegmentedButton<bool>(
                                          segments: const [
                                            ButtonSegment<bool>(
                                              value: false,
                                              label: Text('Sign in'),
                                            ),
                                            ButtonSegment<bool>(
                                              value: true,
                                              label: Text('Create account'),
                                            ),
                                          ],
                                          selected: {_creatingAccount},
                                          showSelectedIcon: false,
                                          onSelectionChanged: _signingIn
                                              ? null
                                              : (selection) => setState(() {
                                                  _creatingAccount =
                                                      selection.first;
                                                  _emailSendFailed = false;
                                                  _error = null;
                                                  _notice = null;
                                                }),
                                        ),
                                        const SizedBox(height: 18),
                                      ] else ...[
                                        Text(
                                          'Enter your verification code',
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          _creatingAccount
                                              ? 'Enter the 6-digit code sent to ${_emailController.text.trim()} to verify your email and finish creating your account.'
                                              : 'Enter the 6-digit code sent to ${_emailController.text.trim()} to finish signing in.',
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                color: muted,
                                                height: 1.45,
                                              ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          _emailExpiresIn > 0
                                              ? 'Code expires in ${_formatCountdown(_emailExpiresIn)}.'
                                              : 'This code has expired. Resend a new code to continue.',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: _emailExpiresIn > 0
                                                    ? muted
                                                    : theme.colorScheme.error,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                        const SizedBox(height: 18),
                                      ],
                                      Form(
                                        key: _formKey,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            if (_emailChallengeId == null) ...[
                                              Text(
                                                'Email',
                                                style: theme
                                                    .textTheme
                                                    .labelLarge
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              const SizedBox(height: 7),
                                              TextFormField(
                                                controller: _emailController,
                                                enabled: !_signingIn,
                                                keyboardType:
                                                    TextInputType.emailAddress,
                                                textInputAction:
                                                    TextInputAction.next,
                                                autofillHints: const [
                                                  AutofillHints.email,
                                                ],
                                                decoration:
                                                    const InputDecoration(
                                                      hintText:
                                                          'name@example.com',
                                                    ),
                                                validator: (value) {
                                                  final email =
                                                      value?.trim() ?? '';
                                                  if (email.isEmpty ||
                                                      !email.contains('@')) {
                                                    return 'Enter a valid email address.';
                                                  }
                                                  return null;
                                                },
                                              ),
                                              const SizedBox(height: 14),
                                              Text(
                                                'Password',
                                                style: theme
                                                    .textTheme
                                                    .labelLarge
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              const SizedBox(height: 7),
                                              TextFormField(
                                                controller: _passwordController,
                                                enabled: !_signingIn,
                                                obscureText: _hidePassword,
                                                textInputAction:
                                                    TextInputAction.done,
                                                autofillHints: [
                                                  _creatingAccount
                                                      ? AutofillHints
                                                            .newPassword
                                                      : AutofillHints.password,
                                                ],
                                                onFieldSubmitted: (_) {
                                                  if (!_signingIn) {
                                                    _submitEmailPassword();
                                                  }
                                                },
                                                decoration: InputDecoration(
                                                  hintText:
                                                      'Enter your password',
                                                  suffixIcon: IconButton(
                                                    onPressed: () => setState(
                                                      () => _hidePassword =
                                                          !_hidePassword,
                                                    ),
                                                    tooltip: _hidePassword
                                                        ? 'Show password'
                                                        : 'Hide password',
                                                    icon: Icon(
                                                      _hidePassword
                                                          ? Icons
                                                                .visibility_outlined
                                                          : Icons
                                                                .visibility_off_outlined,
                                                    ),
                                                  ),
                                                ),
                                                validator: (value) {
                                                  if ((value ?? '').length <
                                                      6) {
                                                    return 'Password must be at least 6 characters.';
                                                  }
                                                  return null;
                                                },
                                              ),
                                              if (_creatingAccount) ...[
                                                const SizedBox(height: 7),
                                                Text(
                                                  'Use at least 6 characters. We’ll send a 6-digit code to verify your email.',
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: muted,
                                                        height: 1.4,
                                                      ),
                                                ),
                                              ],
                                            ] else ...[
                                              TextFormField(
                                                controller: _otpController,
                                                enabled: !_signingIn,
                                                keyboardType:
                                                    TextInputType.number,
                                                textInputAction:
                                                    TextInputAction.done,
                                                autofillHints: const [
                                                  AutofillHints.oneTimeCode,
                                                ],
                                                inputFormatters: [
                                                  FilteringTextInputFormatter
                                                      .digitsOnly,
                                                  LengthLimitingTextInputFormatter(
                                                    6,
                                                  ),
                                                ],
                                                maxLength: 6,
                                                autofocus: true,
                                                textAlign: TextAlign.center,
                                                style: theme
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.copyWith(
                                                      letterSpacing: 10,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                decoration:
                                                    const InputDecoration(
                                                      hintText: '000000',
                                                      counterText: '',
                                                    ),
                                                onFieldSubmitted: (_) {
                                                  if (!_signingIn)
                                                    _verifyEmailOtp();
                                                },
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      if (_emailChallengeId == null &&
                                          !_creatingAccount)
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: TextButton(
                                            onPressed: _signingIn
                                                ? null
                                                : _resetPassword,
                                            child: Text(
                                              _busyAction == 'reset'
                                                  ? 'Sending reset link…'
                                                  : 'Forgot password?',
                                            ),
                                          ),
                                        )
                                      else if (_emailChallengeId == null)
                                        const SizedBox(height: 12),
                                      if (_emailChallengeId != null)
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            TextButton(
                                              onPressed: _signingIn
                                                  ? null
                                                  : _useDifferentEmail,
                                              child: const Text(
                                                'Use another email',
                                              ),
                                            ),
                                            TextButton(
                                              onPressed:
                                                  _signingIn ||
                                                      _emailResendIn > 0
                                                  ? null
                                                  : _resendEmailOtp,
                                              child: Text(
                                                _busyAction == 'resend'
                                                    ? 'Sending new code…'
                                                    : _emailResendIn > 0
                                                    ? 'Resend in ${_emailResendIn}s'
                                                    : 'Resend code',
                                              ),
                                            ),
                                          ],
                                        ),
                                      FilledButton(
                                        onPressed:
                                            _signingIn ||
                                                (_emailChallengeId == null &&
                                                    _emailResendIn > 0) ||
                                                (_emailChallengeId != null &&
                                                    _emailExpiresIn <= 0)
                                            ? null
                                            : _submitEmailPassword,
                                        style: FilledButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            54,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                        ),
                                        child:
                                            _busyAction == 'verify' ||
                                                _busyAction == 'email' ||
                                                _busyAction == 'signup'
                                            ? _ButtonProgressLabel(
                                                label: _busyAction == 'verify'
                                                    ? 'Verifying code…'
                                                    : _busyAction == 'signup'
                                                    ? 'Creating account…'
                                                    : 'Sending sign-in code…',
                                              )
                                            : Text(
                                                _emailChallengeId != null
                                                    ? _emailExpiresIn <= 0
                                                          ? 'Code expired'
                                                          : 'Verify code'
                                                    : _emailResendIn > 0
                                                    ? 'Try again in ${_emailResendIn}s'
                                                    : _emailSendFailed
                                                    ? 'Retry sending code'
                                                    : _creatingAccount
                                                    ? 'Create account'
                                                    : 'Send sign-in code',
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                      ),
                                      if (_emailSendFailed ||
                                          _emailResendIn > 0 ||
                                          _emailRateLimitHint) ...[
                                        const SizedBox(height: 10),
                                        _MessageBox(
                                          message: _emailResendIn > 0
                                              ? 'Your email and password are still here. You can request another code in ${_emailResendIn}s.${_emailRateLimitHint ? ' Hourly limits may require a longer wait.' : ''}'
                                              : _emailRateLimitHint
                                              ? 'Your email and password are still here. Hourly limits may require more time than this countdown.'
                                              : 'Your email and password are still here. Retry to request a verification code.',
                                          isError: false,
                                        ),
                                      ],
                                      if (_error != null) ...[
                                        const SizedBox(height: 10),
                                        _MessageBox(
                                          message: _error!,
                                          isError: true,
                                        ),
                                      ],
                                      if (_notice != null) ...[
                                        const SizedBox(height: 10),
                                        _MessageBox(
                                          message: _notice!,
                                          isError: false,
                                        ),
                                      ],
                                      if (widget.authService == null) ...[
                                        const SizedBox(height: 16),
                                        _MessageBox(
                                          message: widget.setupError == null
                                              ? 'Firebase setup is required before sign-in can work. Add the Firebase app settings and enable Google or Email/Password sign-in.'
                                              : 'Firebase could not initialize. Check the app configuration, then restart the app.',
                                          isError: false,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  'Your documents stay in your local workspace on this device.',
                                  textAlign: TextAlign.start,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: muted,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SignInIntro extends StatelessWidget {
  const _SignInIntro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Every document,\nreadable.',
          style: theme.textTheme.headlineLarge?.copyWith(
            fontSize: 42,
            height: 1.12,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Scan, extract, and understand Khmer and English text in one focused workspace.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          'ស្កាន អាន និងរក្សាទុកអត្ថបទរបស់អ្នក',
          style: theme.textTheme.titleLarge?.copyWith(height: 1.7),
        ),
        const SizedBox(height: 30),
        const _SignInFeature(
          icon: Icons.document_scanner_outlined,
          text: 'Khmer and English OCR',
        ),
        const SizedBox(height: 14),
        const _SignInFeature(
          icon: Icons.folder_outlined,
          text: 'A document history on your device',
        ),
        const SizedBox(height: 14),
        const _SignInFeature(
          icon: Icons.light_mode_outlined,
          text: 'Comfortable light and dark reading',
        ),
      ],
    );
  }
}

class _SignInFeature extends StatelessWidget {
  const _SignInFeature({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 21, color: AppTheme.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
        ),
      ],
    );
  }
}

class _ButtonProgressLabel extends StatelessWidget {
  const _ButtonProgressLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const SizedBox.square(
        dimension: 19,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => const AppBrandMark(size: 44);
}

class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 22,
    child: CustomPaint(painter: _GoogleLogoPainter()),
  );
}

class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  static const _blue = Color(0xFF4285F4);
  static const _red = Color(0xFFEA4335);
  static const _yellow = Color(0xFFFBBC05);
  static const _green = Color(0xFF34A853);

  @override
  void paint(Canvas canvas, Size size) {
    final diameter = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = diameter * .36;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final gap = math.pi * .035;
    final strokeWidth = diameter * .18;
    final arcPaint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    void drawSegment(Color color, double start, double sweep) {
      arcPaint.color = color;
      canvas.drawArc(rect, start, sweep, false, arcPaint);
    }

    final quadrantSweep = math.pi / 2 - gap * 2;
    drawSegment(_red, -math.pi * .75 + gap, quadrantSweep);
    drawSegment(_yellow, math.pi * .75 + gap, quadrantSweep);
    drawSegment(_green, math.pi * .25 + gap, quadrantSweep);
    drawSegment(_blue, -math.pi * .25 + gap, quadrantSweep);

    final barPaint = Paint()
      ..isAntiAlias = true
      ..color = _blue
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;
    canvas.drawLine(
      center,
      Offset(size.width - diameter * .07, center.dy),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GoogleLogoPainter oldDelegate) => false;
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? Theme.of(context).colorScheme.error
        : AppTheme.accent;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
