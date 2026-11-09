import 'package:flutter/foundation.dart';

/// True only when running as the Windows desktop app (never on web/Android/iOS).
bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
