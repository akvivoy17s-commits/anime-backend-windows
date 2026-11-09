# Google sign-in on Windows - one-time setup

1. Google Cloud Console -> select project of your Firebase app (animeapp-608c0)
   -> APIs & Services -> Credentials -> Create credentials -> OAuth client ID
   -> Application type: **Desktop app** -> Create.
   Copy the Client ID and Client secret.
   (If it asks, finish the "OAuth consent screen" first; add your Gmail as a test user.)
2. Firebase Console -> Authentication -> Sign-in method -> Google -> expand
   "Safelist client IDs from external projects" -> add the Desktop Client ID. Save.
   (Needed only if sign-in says invalid audience / INVALID_IDP_RESPONSE.)
3. Put the keys in the `.env` file (project root, next to pubspec.yaml; copy from `.env.example`):

```
GOOGLE_DESKTOP_CLIENT_ID=xxxx.apps.googleusercontent.com
GOOGLE_DESKTOP_CLIENT_SECRET=yyyy
```
Then just run / build normally (run `flutter pub get` once after pulling this change):

```
flutter run -d windows
flutter build windows --release
```
`.env` is git-ignored - never commit it. (`--dart-define=GOOGLE_DESKTOP_CLIENT_ID=... --dart-define=GOOGLE_DESKTOP_CLIENT_SECRET=...` still works as a fallback.)
Click "Continue with Google" -> your browser opens -> choose account -> come back to the app.
