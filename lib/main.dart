import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import 'pages/home.dart';
import 'pages/login.dart';
import 'firebase_options.dart';
import 'logging.dart';
import 'services/admin_service.dart';
import 'services/download_service.dart';
import 'services/desktop_video_platform.dart';
import 'services/platform_flags.dart';
import 'services/session_service.dart';
import 'ui/desktop.dart';
import 'ui/neo.dart';
import 'ui/session_gate.dart';
import 'ui/splash_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  configureLogging();

  // Loads secrets such as GOOGLE_DESKTOP_CLIENT_ID / GOOGLE_DESKTOP_CLIENT_SECRET from the .env asset.
  // Optional: the app still starts if the file is missing.
  await dotenv.load(fileName: '.env', isOptional: true);

  // Windows: play videos with media_kit (libmpv) - handles Google Drive streaming, MKV, HEVC.
  // Other platforms keep the normal video_player.
  if (isWindows) {
    VideoPlayerMediaKit.ensureInitialized(
      android: false,
      iOS: false,
      macOS: false,
      windows: true,
      linux: false,
      web: false,
    );
    // adds audio-track (language) support on Windows
    AudioAwareMediaKitPlayer.register();
  }

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // google_sign_in has no Windows implementation; Windows uses email/password.
  if (!isWindows) {
    await GoogleSignIn.instance.initialize(
      clientId: kIsWeb ? 'YOUR_WEB_CLIENT_ID' : null,
    );
  }

  AdminService.init();
  SessionService.init();
  await DownloadService.init();

  runApp(const MainApp());
}

// ============================================================
// MAIN APP
// ============================================================

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: SessionService.navigatorKey,
      title: 'Anime Portal',
      theme: Neo.theme(),
      scrollBehavior: const DesktopScrollBehavior(),
      builder: (context, child) {
        // keeps layouts safe when users set very large system fonts
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.15,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const _Root(),
    );
  }
}

// ============================================================
// ROOT: splash first, then auth gate
// ============================================================

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _splashDone = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: _splashDone
          ? const AuthGate(key: ValueKey('gate'))
          : SplashPage(
              key: const ValueKey('splash'),
              onDone: () {
                if (mounted) setState(() => _splashDone = true);
              },
            ),
    );
  }
}

// ============================================================
// AUTH GATE
// ============================================================

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Neo.bg,
            body: Center(child: CircularProgressIndicator(color: Neo.cyan)),
          );
        }

        if (snapshot.hasData) {
          return const SessionGate(child: HomePage());
        }

        return const LoginPage();
      },
    );
  }
}
