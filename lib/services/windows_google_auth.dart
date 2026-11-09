import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Google sign-in for Windows (google_sign_in has no Windows support).
/// Opens the system browser, receives the result on a local 127.0.0.1 port (OAuth "loopback" + PKCE),
/// then returns a Firebase credential: FirebaseAuth.instance.signInWithCredential(await signIn()).
///
/// Needs an OAuth client of type "Desktop app" (Google Cloud Console > APIs & Services > Credentials).
/// Put the keys in the `.env` file in the project root (see `.env.example`):
///   GOOGLE_DESKTOP_CLIENT_ID=xxx.apps.googleusercontent.com
///   GOOGLE_DESKTOP_CLIENT_SECRET=yyy
/// (`--dart-define=GOOGLE_DESKTOP_CLIENT_ID=... --dart-define=GOOGLE_DESKTOP_CLIENT_SECRET=...` still works as a fallback.)
class WindowsGoogleAuth {
  WindowsGoogleAuth._();

  // Fallback only: values passed with --dart-define (used when .env has no value).
  static const String _defineClientId = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');
  static const String _defineClientSecret = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET');

  /// .env value first, then --dart-define, else ''.
  static String _read(String key, String fallback) {
    if (dotenv.isInitialized) {
      final v = (dotenv.maybeGet(key) ?? '').trim();
      if (v.isNotEmpty && !v.startsWith('YOUR_')) return v;
    }
    return fallback.trim();
  }

  static String get clientId => _read('GOOGLE_DESKTOP_CLIENT_ID', _defineClientId);
  static String get clientSecret => _read('GOOGLE_DESKTOP_CLIENT_SECRET', _defineClientSecret);

  static bool get configured =>
      clientId.isNotEmpty &&
      clientSecret.isNotEmpty &&
      !clientId.startsWith('YOUR_') &&
      !clientSecret.startsWith('YOUR_');

  static String _rand(int bytes) {
    final r = Random.secure();
    return base64UrlEncode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  static Future<OAuthCredential> signIn() async {
    if (!configured) {
      throw StateError('Windows Google sign-in is not set up yet (GOOGLE_DESKTOP_CLIENT_ID / GOOGLE_DESKTOP_CLIENT_SECRET missing in .env).');
    }

    final verifier = _rand(64);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _rand(16);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';

    try {
      final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': clientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': 'openid email profile',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'prompt': 'select_account',
      });

      // opens the default browser (no extra package needed on Windows)
      await Process.run('rundll32', ['url.dll,FileProtocolHandler', authUrl.toString()]);

      final code = await _waitForCode(server, state).timeout(
        const Duration(minutes: 3),
        onTimeout: () => throw StateError('Google sign-in timed out. Please try again.'),
      );

      final resp = await http.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        body: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'code': code,
          'code_verifier': verifier,
          'redirect_uri': redirect,
          'grant_type': 'authorization_code',
        },
      );
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode != 200) {
        throw StateError('Google error: ${data['error_description'] ?? data['error'] ?? resp.statusCode}');
      }
      final idToken = data['id_token'] as String?;
      if (idToken == null || idToken.isEmpty) {
        throw StateError('Google did not return an ID token');
      }
      return GoogleAuthProvider.credential(
        idToken: idToken,
        accessToken: data['access_token'] as String?,
      );
    } finally {
      await server.close(force: true);
    }
  }

  static Future<String> _waitForCode(HttpServer server, String state) async {
    await for (final req in server) {
      final q = req.uri.queryParameters;
      if (!q.containsKey('code') && !q.containsKey('error')) {
        // favicon etc.
        req.response.statusCode = 404;
        await req.response.close();
        continue;
      }
      final ok = q.containsKey('code') && q['state'] == state;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body style="font-family:sans-serif;text-align:center;margin-top:15vh">'
            '<h2>${ok ? 'Sign-in complete' : 'Sign-in failed'}</h2>'
            '<p>You can close this tab and go back to Anime Portal.</p></body></html>');
      await req.response.close();
      if (!ok) {
        throw StateError(q['error'] == 'access_denied' ? 'Sign-in was cancelled.' : 'Google sign-in failed.');
      }
      return q['code']!;
    }
    throw StateError('Google sign-in was cancelled.');
  }
}
