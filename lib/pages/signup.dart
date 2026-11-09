import 'dart:math' as math;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import './home.dart';
import '../services/user_firestore_service.dart';
import '../ui/neo.dart';
import '../services/platform_flags.dart';
import '../services/windows_google_auth.dart';
import '../ui/google_logo.dart';
import '../ui/splash_page.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  // ============================================================
  // CONTROLLERS
  // ============================================================

  final TextEditingController nameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController =
      TextEditingController();
  final TextEditingController confirmPasswordController =
      TextEditingController();

  // ============================================================
  // STATE
  // ============================================================

  bool isLoading = false;
  bool obscurePassword = true;
  bool obscureConfirmPassword = true;

  // ============================================================
  // EMAIL / PASSWORD SIGN UP
  // ============================================================

  Future<void> createAccount() async {
    final String name = nameController.text.trim();
    final String email = emailController.text.trim();
    final String password = passwordController.text;
    final String confirmPassword =
        confirmPasswordController.text;

    // ----------------------------------------------------------
    // VALIDATION
    // ----------------------------------------------------------

    if (name.isEmpty) {
      showMessage('Please enter your name');
      return;
    }

    if (email.isEmpty) {
      showMessage('Please enter your email');
      return;
    }

    if (password.isEmpty) {
      showMessage('Please enter a password');
      return;
    }

    if (password.length < 6) {
      showMessage(
        'Password must be at least 6 characters',
      );
      return;
    }

    if (confirmPassword.isEmpty) {
      showMessage('Please confirm your password');
      return;
    }

    if (password != confirmPassword) {
      showMessage('Passwords do not match');
      return;
    }

    // ----------------------------------------------------------
    // LOADING
    // ----------------------------------------------------------

    setState(() {
      isLoading = true;
    });

    try {
      // --------------------------------------------------------
      // CREATE FIREBASE ACCOUNT
      // --------------------------------------------------------

      final UserCredential credential =
          await FirebaseAuth.instance
              .createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      final User? user = credential.user;

      if (user == null) {
        throw FirebaseAuthException(
          code: 'user-not-created',
          message: 'Unable to create account',
        );
      }

      // --------------------------------------------------------
      // SAVE DISPLAY NAME
      // --------------------------------------------------------

      await user.updateDisplayName(name);

      await user.reload();

      final User? updatedUser =
          FirebaseAuth.instance.currentUser;

      if (updatedUser != null) {
        await UserFirestoreService.saveSignedInUser(
          updatedUser,
        );
      }

      // --------------------------------------------------------
      // GO TO HOME
      // --------------------------------------------------------

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const HomePage(),
        ),
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Something went wrong';

      switch (e.code) {
        case 'email-already-in-use':
          message =
              'An account already exists with this email';
          break;

        case 'invalid-email':
          message =
              'Please enter a valid email address';
          break;

        case 'weak-password':
          message =
              'Please choose a stronger password';
          break;

        case 'operation-not-allowed':
          message =
              'Email/Password sign-in is not enabled';
          break;

        case 'network-request-failed':
          message =
              'Please check your internet connection';
          break;

        default:
          message =
              e.message ?? 'Unable to create account';
      }

      showMessage(message);
    } catch (e) {
      showMessage(
        'Unable to create account',
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
  // GOOGLE SIGN UP
  // ============================================================

  Future<void> signUpWithGoogle() async {
    if (isLoading) return;

    setState(() {
      isLoading = true;
    });

    try {
      late final UserCredential userCredential;

      // --------------------------------------------------------
      // WEB
      // --------------------------------------------------------

      if (kIsWeb) {
        final GoogleAuthProvider provider =
            GoogleAuthProvider();

        provider.setCustomParameters({
          'prompt': 'select_account',
        });

        userCredential =
            await FirebaseAuth.instance.signInWithPopup(
          provider,
        );
      }

      // --------------------------------------------------------
      // ANDROID / IOS
      // --------------------------------------------------------

      else if (isWindows) {
        userCredential = await FirebaseAuth.instance.signInWithCredential(
          await WindowsGoogleAuth.signIn(),
        );
      }

      else {
        await GoogleSignIn.instance.signOut();

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

        userCredential =
            await FirebaseAuth.instance.signInWithCredential(
          credential,
        );
      }

      // --------------------------------------------------------
      // USER
      // --------------------------------------------------------

      final User? user = userCredential.user;

      if (user == null) {
        throw StateError(
          'Unable to get Google user',
        );
      }

      // --------------------------------------------------------
      // OPTIONAL NAME
      // --------------------------------------------------------
      //
      // If user typed a name before Google signup,
      // use that name as Firebase display name.
      //
      // Otherwise Google account name will remain.
      // --------------------------------------------------------

      final String name = nameController.text.trim();

      if (name.isNotEmpty) {
        await user.updateDisplayName(name);
        await user.reload();
      }

      // --------------------------------------------------------
      // SAVE USER TO FIRESTORE
      // --------------------------------------------------------

      final User? updatedUser =
          FirebaseAuth.instance.currentUser;

      if (updatedUser != null) {
        await UserFirestoreService.saveSignedInUser(
          updatedUser,
        );
      }

      // --------------------------------------------------------
      // GO TO HOME
      // --------------------------------------------------------

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const HomePage(),
        ),
      );
    } on GoogleSignInException catch (e) {
      showMessage(
        'Google sign-up failed: ${e.code.name}',
      );
    } on FirebaseAuthException catch (e) {
      showMessage(
        'Google sign-up failed: ${e.code}',
      );
    } on StateError catch (e) {
      showMessage(
        'Google sign-up failed: ${e.message}',
      );
    } on FirebaseException catch (e) {
      showMessage(
        'Firestore save failed: ${e.code}',
      );
    } catch (e) {
      showMessage(
        'Google sign-up failed: $e',
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

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ============================================================
  // INPUT DECORATION
  // ============================================================

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();

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
                          const Center(child: NeoOrb(size: 96)),
                          const SizedBox(height: 14),
                          const SectionHeader(
                            title: 'Create Account',
                            tag: 'Access // Register',
                            color: Neo.cyan,
                          ),
                          const SizedBox(height: 6),
                          const Padding(
                            padding: EdgeInsets.only(left: 15),
                            child: Text(
                              'Create your account and start watching anime',
                              style: TextStyle(color: Neo.muted, fontSize: 13),
                            ),
                          ),
                          const SizedBox(height: 18),
                          GlassCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                NeoField(
                                  controller: nameController,
                                  label: 'Name',
                                  hint: 'Enter your name',
                                  icon: Icons.person_outline,
                                  keyboardType: TextInputType.name,
                                  action: TextInputAction.next,
                                  autofill: const [AutofillHints.name],
                                ),
                                const SizedBox(height: 14),
                                NeoField(
                                  controller: emailController,
                                  label: 'Email',
                                  hint: 'Enter your email',
                                  icon: Icons.alternate_email,
                                  keyboardType: TextInputType.emailAddress,
                                  action: TextInputAction.next,
                                  autofill: const [AutofillHints.email],
                                ),
                                const SizedBox(height: 14),
                                NeoField(
                                  controller: passwordController,
                                  label: 'Password',
                                  hint: 'Create a password',
                                  icon: Icons.lock_outline,
                                  obscure: obscurePassword,
                                  onToggleObscure: () => setState(
                                    () => obscurePassword = !obscurePassword,
                                  ),
                                  action: TextInputAction.next,
                                  autofill: const [AutofillHints.newPassword],
                                ),
                                const SizedBox(height: 14),
                                NeoField(
                                  controller: confirmPasswordController,
                                  label: 'Confirm Password',
                                  hint: 'Re-enter your password',
                                  icon: Icons.verified_user_outlined,
                                  obscure: obscureConfirmPassword,
                                  onToggleObscure: () => setState(
                                    () => obscureConfirmPassword =
                                        !obscureConfirmPassword,
                                  ),
                                  action: TextInputAction.done,
                                  onSubmitted: (_) {
                                    if (!isLoading) createAccount();
                                  },
                                ),
                                const SizedBox(height: 20),
                                NeoButton(
                                  label: 'CREATE ACCOUNT',
                                  icon: Icons.rocket_launch_outlined,
                                  loading: isLoading,
                                  onTap: createAccount,
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
                                  label: 'Sign up with Google',
                                  leading: const GoogleLogo(size: 26),
                                  onTap: isLoading ? null : signUpWithGoogle,
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
                                      Navigator.pop(context);
                                    },
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Text.rich(
                                  TextSpan(
                                    text: 'Already have an account? ',
                                    style: TextStyle(color: Neo.muted),
                                    children: [
                                      TextSpan(
                                        text: 'Login',
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

