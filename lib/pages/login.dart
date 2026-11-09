import 'dart:math' as math;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'home.dart';
import 'signup.dart';
import '../services/user_firestore_service.dart';
import '../ui/neo.dart';
import '../services/platform_flags.dart';
import '../services/windows_google_auth.dart';
import '../ui/google_logo.dart';
import '../ui/splash_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController emailController =
      TextEditingController();

  final TextEditingController passwordController =
      TextEditingController();

  bool isLoading = false;
  bool obscurePassword = true;

  // ============================================================
  // EMAIL LOGIN
  // ============================================================

  Future<void> loginWithEmail() async {
    if (emailController.text.trim().isEmpty ||
        passwordController.text.isEmpty) {
      showMessage('Please enter email and password');
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final credential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text,
      );

      if (credential.user != null) {
        await UserFirestoreService.saveSignedInUser(
          credential.user!,
        );
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const HomePage(),
        ),
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Login failed';

      if (e.code == 'user-not-found') {
        message = 'No account found with this email';
      } else if (e.code == 'wrong-password' ||
          e.code == 'invalid-credential') {
        message = 'Incorrect email or password';
      } else if (e.code == 'invalid-email') {
        message = 'Please enter a valid email';
      } else if (e.code == 'user-disabled') {
        message = 'This account has been disabled';
      } else if (e.code == 'too-many-requests') {
        message = 'Too many attempts. Please try again later';
      }

      showMessage(message);
    } on FirebaseException catch (e) {
      showMessage(
        'Firestore save failed: ${e.code}',
      );
    } catch (e) {
      showMessage('Login failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // ============================================================
  // GOOGLE LOGIN
  // ============================================================

  Future<void> loginWithGoogle() async {
    setState(() {
      isLoading = true;
    });

    try {
      if (kIsWeb) {
        final GoogleAuthProvider provider =
            GoogleAuthProvider();

        provider.setCustomParameters({
          'prompt': 'select_account',
        });

        final UserCredential credential =
            await FirebaseAuth.instance.signInWithPopup(
          provider,
        );

        if (credential.user != null) {
          await UserFirestoreService.saveSignedInUser(
            credential.user!,
          );
        }
      } else if (isWindows) {
        final UserCredential userCredential =
            await FirebaseAuth.instance.signInWithCredential(
          await WindowsGoogleAuth.signIn(),
        );

        if (userCredential.user != null) {
          await UserFirestoreService.saveSignedInUser(
            userCredential.user!,
          );
        }
      } else {
        final GoogleSignInAccount googleUser =
            await GoogleSignIn.instance.authenticate();

        final GoogleSignInAuthentication googleAuth =
            googleUser.authentication;

        if (googleAuth.idToken == null) {
          throw StateError(
            'Google did not return an ID token',
          );
        }

        final OAuthCredential credential =
            GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );

        final UserCredential userCredential =
            await FirebaseAuth.instance.signInWithCredential(
          credential,
        );

        if (userCredential.user != null) {
          await UserFirestoreService.saveSignedInUser(
            userCredential.user!,
          );
        }
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const HomePage(),
        ),
      );
    } on GoogleSignInException catch (e) {
      showMessage(
        'Google sign-in failed: ${e.code.name}',
      );
    } on FirebaseAuthException catch (e) {
      showMessage(
        'Google sign-in failed: ${e.code}',
      );
    } on FirebaseException catch (e) {
      showMessage(
        'Firestore save failed: ${e.code}',
      );
    } on StateError catch (e) {
      showMessage(
        'Google sign-in failed: ${e.message}',
      );
    } catch (e) {
      showMessage(
        'Google sign-in failed: $e',
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // ============================================================
  // MESSAGE
  // ============================================================

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  // ============================================================
  // BUILD
  // ============================================================


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: NeoBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              return SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: math.max(0.0, c.maxHeight - 32),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Center(child: NeoOrb(size: 120)),
                          const SizedBox(height: 6),
                          const Center(
                            child: Text(
                              Neo.appName,
                              style: TextStyle(
                                color: Neo.text,
                                fontFamily: Neo.mono,
                                fontWeight: FontWeight.w800,
                                fontSize: 22,
                                letterSpacing: 3,
                              ),
                            ),
                          ),
                          const SizedBox(height: 22),
                          const SectionHeader(
                            title: 'Welcome Back',
                            tag: 'Access // Sign In',
                          ),
                          const SizedBox(height: 6),
                          const Padding(
                            padding: EdgeInsets.only(left: 15),
                            child: Text(
                              'Sign in to continue watching anime',
                              style: TextStyle(color: Neo.muted, fontSize: 13),
                            ),
                          ),
                          const SizedBox(height: 18),
                          GlassCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                NeoField(
                                  controller: emailController,
                                  label: 'Email',
                                  hint: 'Enter your email',
                                  icon: Icons.alternate_email,
                                  keyboardType: TextInputType.emailAddress,
                                  action: TextInputAction.next,
                                  autofill: const [AutofillHints.email],
                                ),
                                const SizedBox(height: 16),
                                NeoField(
                                  controller: passwordController,
                                  label: 'Password',
                                  hint: 'Enter your password',
                                  icon: Icons.lock_outline,
                                  obscure: obscurePassword,
                                  onToggleObscure: () => setState(
                                    () => obscurePassword = !obscurePassword,
                                  ),
                                  action: TextInputAction.done,
                                  autofill: const [AutofillHints.password],
                                  onSubmitted: (_) {
                                    if (!isLoading) loginWithEmail();
                                  },
                                ),
                                const SizedBox(height: 16),
                                NeoButton(
                                  label: 'LOGIN',
                                  icon: Icons.bolt_rounded,
                                  loading: isLoading,
                                  onTap: loginWithEmail,
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    Expanded(child: Divider(color: Neo.line)),
                                    const Padding(
                                      padding:
                                          EdgeInsets.symmetric(horizontal: 12),
                                      child: Text(
                                        'OR',
                                        style: TextStyle(
                                          color: Neo.muted,
                                          fontFamily: Neo.mono,
                                          fontSize: 11,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                    ),
                                    Expanded(child: Divider(color: Neo.line)),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                NeoGhostButton(
                                  label: 'Continue with Google',
                                  leading: const GoogleLogo(size: 26),
                                  onTap: isLoading ? null : loginWithGoogle,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          Center(
                            child: GestureDetector(
                              onTap: isLoading
                                  ? null
                                  : () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => const SignUpPage(),
                                        ),
                                      );
                                    },
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Text.rich(
                                  TextSpan(
                                    text: "Don't have an account? ",
                                    style: TextStyle(color: Neo.muted),
                                    children: [
                                      TextSpan(
                                        text: 'Sign Up',
                                        style: TextStyle(
                                          color: Neo.cyan,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

