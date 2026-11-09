# Windows build

flutter config --enable-windows-desktop
flutter pub get
flutter run -d windows            # test (Google keys go in .env - see GOOGLE_SIGNIN_WINDOWS.md)
flutter build windows --release   # final (first build ~18 min, next ones faster)

Output: build\windows\x64\runner\Release\  -> share the WHOLE folder (exe + dlls + data), or use installer.iss (Inno Setup).
Do NOT ship backend/serviceAccount.json or backend/.env.
