import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_otp_api.dart';
import '../widgets/app_ui.dart';

class OtpVerificationScreen extends StatefulWidget {
  const OtpVerificationScreen({
    super.key,
    required this.user,
    required this.onVerified,
  });

  final User user;
  final VoidCallback onVerified;

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  final _codeController = TextEditingController();
  final _api = AuthOtpApi();
  String? _challengeId;
  String? _error;
  bool _deliveryFailed = false;
  bool _rateLimitHint = false;
  bool _busy = true;
  String? _busyAction;
  int _resendIn = 0;
  int _expiresIn = 0;
  Timer? _cooldown;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    _expiryTimer?.cancel();
    _codeController.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _busyAction = 'send';
      _error = null;
      _rateLimitHint = false;
    });
    try {
      final token = await widget.user.getIdToken();
      if (token == null)
        throw const AuthOtpApiException('Sign in again to continue.');
      final tokenResult = await widget.user.getIdTokenResult();
      final challengeId = tokenResult.claims?['otp_challenge_id'];
      if (challengeId is String) {
        await _api.completeSession(token);
        if (mounted) widget.onVerified();
        return;
      }
      final response = await _api.startForSignedInUser(token);
      if (response is AuthOtpVerified) {
        // The router will confirm this with /session/status before opening
        // the app. Keep this response out of the OTP completion path.
        if (mounted) widget.onVerified();
        return;
      }
      final challenge = response as AuthOtpChallenge;
      if (!mounted) return;
      setState(() {
        _challengeId = challenge.id;
        _deliveryFailed = false;
        _codeController.clear();
      });
      _startCooldown();
      _startExpiryCountdown(challenge.expiresInSeconds);
    } on AuthOtpApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _deliveryFailed = _challengeId == null;
          _rateLimitHint = error.isRateLimited;
        });
        if (error.isRateLimited || _challengeId != null) {
          _startCooldown(
            error.isRateLimited ? error.retryAfterSeconds ?? 60 : 60,
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not start email verification. Try again.';
          _deliveryFailed = _challengeId == null;
        });
        if (_challengeId != null) _startCooldown();
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyAction = null;
        });
      }
    }
  }

  void _startCooldown([int seconds = 60]) {
    _cooldown?.cancel();
    setState(() => _resendIn = seconds < 1 ? 60 : seconds);
    _cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      if (_resendIn <= 1) {
        timer.cancel();
        setState(() => _resendIn = 0);
      } else {
        setState(() => _resendIn--);
      }
    });
  }

  void _startExpiryCountdown(int expiresInSeconds) {
    _expiryTimer?.cancel();
    setState(() => _expiresIn = expiresInSeconds < 0 ? 0 : expiresInSeconds);
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      if (_expiresIn <= 1) {
        timer.cancel();
        setState(() => _expiresIn = 0);
      } else {
        setState(() => _expiresIn--);
      }
    });
  }

  String _formatCountdown(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  Future<void> _resend() async {
    if (_resendIn > 0 || _busy) return;
    _codeController.clear();
    await _start();
  }

  Future<void> _verify() async {
    final challengeId = _challengeId;
    final code = _codeController.text.trim();
    if (challengeId == null) return;
    if (_expiresIn <= 0) {
      setState(
        () => _error = 'This code has expired. Request a new code to continue.',
      );
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() {
      _busy = true;
      _busyAction = 'verify';
      _error = null;
    });
    try {
      final token = await widget.user.getIdToken();
      if (token == null)
        throw const AuthOtpApiException('Sign in again to continue.');
      final customToken = await _api.verifyCode(
        challengeId: challengeId,
        code: code,
        idToken: token,
      );
      if (customToken != null) {
        throw const AuthOtpApiException('This sign-in needs to be restarted.');
      }
      if (mounted) widget.onVerified();
    } on AuthOtpApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Could not verify the code. Try again.');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyAction = null;
        });
      }
    }
  }

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = widget.user.email ?? 'your email address';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const _BrandMark(),
                      const SizedBox(width: 12),
                      Text(
                        'Netra',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 30),
                  Text(
                    'Check your email',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _challengeId == null
                        ? 'Email verification is required to continue. We’ll send a 6-digit code to $email.'
                        : 'Enter the 6-digit code we sent to $email to finish signing in.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  if (_deliveryFailed) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Your Google sign-in is still active. Retry sending the code below; you do not need to sign in again.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  if (_challengeId != null) ...[
                    TextFormField(
                      controller: _codeController,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      maxLength: 6,
                      autofocus: true,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        letterSpacing: 10,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: const InputDecoration(
                        hintText: '000000',
                        counterText: '',
                      ),
                      onFieldSubmitted: (_) {
                        if (!_busy) _verify();
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _expiresIn > 0
                          ? 'Code expires in ${_formatCountdown(_expiresIn)}.'
                          : 'This code has expired. Resend a new code to continue.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _expiresIn > 0
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy || (_challengeId == null && _resendIn > 0)
                        ? null
                        : _challengeId == null
                        ? _start
                        : _expiresIn > 0
                        ? _verify
                        : null,
                    child:
                        _busy &&
                            (_challengeId == null || _busyAction == 'verify')
                        ? _ButtonProgressLabel(
                            label: _busyAction == 'verify'
                                ? 'Verifying code…'
                                : 'Sending verification code…',
                          )
                        : Text(
                            _challengeId == null
                                ? _resendIn > 0
                                      ? 'Try again in ${_resendIn}s'
                                      : _deliveryFailed
                                      ? 'Retry sending code'
                                      : 'Send verification code'
                                : _expiresIn > 0
                                ? 'Verify and continue'
                                : 'Code expired',
                          ),
                  ),
                  if (_challengeId != null) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _resendIn == 0 && !_busy ? _resend : null,
                      child: Text(
                        _busyAction == 'send'
                            ? 'Sending another code…'
                            : _resendIn == 0
                            ? 'Resend code'
                            : 'Resend in $_resendIn sec',
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    _MessageBox(message: _error!),
                  ],
                  if (_rateLimitHint) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Hourly limits may require a longer wait, even after this countdown ends.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _busy ? null : _signOut,
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('Use a different account'),
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

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );
}
