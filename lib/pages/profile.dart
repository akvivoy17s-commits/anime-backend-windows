import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/neo.dart';
import '../ui/refresh.dart';
import '../services/admin_service.dart';
import '../services/session_service.dart';
import 'controls.dart';
import 'drive_agent.dart';
import 'login.dart';
import 'manage_video.dart';
import 'upload_method.dart';

class ProfilePage extends StatefulWidget {
  final bool embedded;

  const ProfilePage({
    super.key,
    this.embedded = false,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  User? get currentUser {
    return FirebaseAuth.instance.currentUser;
  }

  bool get isLoggedIn {
    return currentUser != null;
  }

  bool get isAdmin => AdminService.isAdmin;

  void _onAdminChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    AdminService.notifier.addListener(_onAdminChanged);
  }

  @override
  void dispose() {
    AdminService.notifier.removeListener(_onAdminChanged);
    super.dispose();
  }

  void openLogin() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const LoginPage(),
      ),
    );
  }

  Future<void> signOut() async {
    final shouldSignOut = await neoConfirm(
      context,
      title: 'Sign Out',
      message: 'Are you sure you want to sign out?',
      confirmLabel: 'SIGN OUT',
      danger: true,
    );

    if (!shouldSignOut) {
      return;
    }

    await SessionService.signOut();

    if (!mounted) {
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const LoginPage(),
      ),
      (route) => false,
    );
  }

  // Goes straight to the method chooser (old duplicate chooser removed).
  void openUploadPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const UploadMethodPage(),
      ),
    );
  }

  void openManageVideoPage() {
    if (!isAdmin) {
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ManageVideoPage(),
      ),
    );
  }

  void openDriveAgentPage() {
    if (!isAdmin) {
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const DriveAgentPage(),
      ),
    );
  }

  void openControlsPage() {
    if (!isAdmin) {
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ControlsPage(),
      ),
    );
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (ctx) => NeoDialog(
        title: Neo.appName,
        sub: 'VERSION 1.0.0',
        icon: Icons.movie_filter_rounded,
        accent: Neo.violet,
        content: const Text(
          'Anime streaming application.',
          style: TextStyle(color: Neo.muted, fontSize: 14, height: 1.45),
        ),
        actions: [
          NeoSmallButton(
            label: 'CLOSE',
            primary: true,
            onTap: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  Future<void> _refresh() async {
    try {
      await FirebaseAuth.instance.currentUser?.reload();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final user = currentUser;

    final list = NeoRefresh(onRefresh: _refresh, child: ListView(
physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        _buildProfileHeader(user),
        const SizedBox(height: 26),
        const SectionHeader(title: 'Account', tag: 'identity', color: Neo.cyan),
        const SizedBox(height: 12),
        if (!isLoggedIn)
          NeoActionTile(
            icon: Icons.login_rounded,
            title: 'Login',
            subtitle: 'Sign in to your account',
            onTap: openLogin,
          )
        else ...[
          NeoActionTile(
            icon: Icons.email_outlined,
            title: 'Email',
            subtitle: user?.email ?? 'No email',
            onTap: () {},
          ),
          if (isAdmin) ...[
            const SizedBox(height: 12),
            _buildAdminBadgeTile(),
          ],
        ],
        if (isAdmin) ...[
          const SizedBox(height: 26),
          const SectionHeader(title: 'Admin', tag: 'control', color: Neo.amber),
          const SizedBox(height: 12),
          NeoActionTile(
            icon: Icons.cloud_upload_rounded,
            title: 'Upload Video',
            subtitle: 'Upload a new video to the app',
            color: Neo.cyan,
            onTap: openUploadPage,
          ),
          const SizedBox(height: 12),
          NeoActionTile(
            icon: Icons.video_settings_rounded,
            title: 'Manage Videos',
            subtitle: 'Edit, delete and manage your videos & playlists',
            color: Neo.violet,
            onTap: openManageVideoPage,
          ),
          const SizedBox(height: 12),
          NeoActionTile(
            icon: Icons.smart_toy_rounded,
            title: 'Drive Agent',
            subtitle: 'Auto-upload every video from a Google Drive folder',
            color: Neo.amber,
            onTap: openDriveAgentPage,
          ),
          const SizedBox(height: 12),
          NeoActionTile(
            icon: Icons.tune_rounded,
            title: 'Controls',
            subtitle: 'Users, login limit & download permission',
            color: Neo.pink,
            onTap: openControlsPage,
          ),
        ],
        const SizedBox(height: 26),
        const SectionHeader(title: 'Settings', tag: 'app', color: Neo.pink),
        const SizedBox(height: 12),
        NeoActionTile(
          icon: Icons.info_outline_rounded,
          title: 'About',
          subtitle: 'Anime App',
          color: Neo.muted,
          onTap: _showAbout,
        ),
        if (isLoggedIn) ...[
          const SizedBox(height: 12),
          NeoActionTile(
            icon: Icons.logout_rounded,
            title: 'Sign Out',
            subtitle: 'Sign out from this account',
            color: Neo.pink,
            onTap: signOut,
          ),
        ],
      ],
    ));

    if (!widget.embedded) {
      return NeoScaffold(
        overline: 'Account // Profile',
        title: 'Profile',
        maxWidth: 720,
        body: list,
      );
    }

    // Embedded inside Home (Home already paints the background).
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                const PageHeader(overline: 'Account // Profile', title: 'Profile'),
                Expanded(child: list),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================
  // PROFILE HEADER (3D tilt card + glowing avatar ring)
  // ===========================================================
  Widget _buildProfileHeader(User? user) {
    final email = user?.email;
    final displayName = user?.displayName;

    final name = displayName != null && displayName.trim().isNotEmpty
        ? displayName
        : email != null && email.contains('@')
            ? email.split('@').first
            : 'Guest';

    const fallbackIcon = Icon(Icons.person_rounded, color: Neo.text, size: 44);

    return Tilt3D(
      onTap: () {},
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Neo.violet.withValues(alpha: 0.35)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Neo.violet.withValues(alpha: 0.22),
              Neo.surface,
              Neo.cyan.withValues(alpha: 0.12),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: Neo.violet.withValues(alpha: 0.18),
              blurRadius: 34,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              width: 100,
              height: 100,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const SweepGradient(
                  colors: [Neo.cyan, Neo.violet, Neo.pink, Neo.cyan],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Neo.violet.withValues(alpha: 0.5),
                    blurRadius: 30,
                  ),
                ],
              ),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Neo.bg2,
                ),
                child: user?.photoURL != null
                    ? ClipOval(
                        child: Image.network(
                          user!.photoURL!,
                          width: 94,
                          height: 94,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => fallbackIcon,
                        ),
                      )
                    : fallbackIcon,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Neo.text,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              email ?? 'Not logged in',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Neo.muted,
                fontFamily: Neo.mono,
                fontSize: 12.5,
              ),
            ),
            if (isAdmin) ...[
              const SizedBox(height: 14),
              const NeoTag('ADMIN ACCESS', color: Neo.amber),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAdminBadgeTile() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Neo.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Neo.amber.withValues(alpha: 0.35)),
      ),
      child: const Row(
        children: [
          Icon(Icons.admin_panel_settings_rounded, color: Neo.amber, size: 26),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Administrator',
                  style: TextStyle(
                    color: Neo.text,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                Text(
                  'You have admin access',
                  style: TextStyle(color: Neo.amber, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
