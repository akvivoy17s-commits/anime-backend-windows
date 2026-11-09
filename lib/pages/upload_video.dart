import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../services/admin_service.dart';
import '../services/google_drive_service.dart';
import '../services/platform_flags.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/neo.dart';

class UploadTestPage extends StatefulWidget {
  const UploadTestPage({super.key});

  @override
  State<UploadTestPage> createState() => _UploadTestPageState();
}

class _UploadTestPageState extends State<UploadTestPage> {
  // ============================================================
  // ADMIN
  // ============================================================

  bool get isAdmin => AdminService.isAdmin;

  // ============================================================
  // VARIABLES
  // ============================================================

  File? videoFile;
  File? thumbnailFile;

  final TextEditingController titleController = TextEditingController();
  final TextEditingController descriptionController =
      TextEditingController();

  bool isUploading = false;

  String uploadStatus = '';

  final Logger logger = Logger('UploadTestPage');

  // ============================================================
  // PICK VIDEO
  // ============================================================

  Future<void> pickVideo() async {
    try {
      final PlatformFile? pickedFile =
          await FilePicker.pickFile(
        type: FileType.video,
      );

      if (pickedFile == null || pickedFile.path == null) {
        return;
      }

      setState(() {
        videoFile = File(pickedFile.path!);
        uploadStatus = '';
      });
    } catch (e) {
      logger.warning('Video picker error: $e');

      showMessage(
        'Video select error: $e',
        isError: true,
      );
    }
  }

  // ============================================================
  // PICK THUMBNAIL
  // ============================================================

  Future<void> pickThumbnail() async {
    try {
      final PlatformFile? pickedFile =
          await FilePicker.pickFile(
        type: FileType.image,
      );

      if (pickedFile == null || pickedFile.path == null) {
        return;
      }

      setState(() {
        thumbnailFile = File(pickedFile.path!);
        uploadStatus = '';
      });
    } catch (e) {
      logger.warning('Thumbnail picker error: $e');

      showMessage(
        'Thumbnail select error: $e',
        isError: true,
      );
    }
  }

  // ============================================================
  // UPLOAD
  // ============================================================

  Future<void> uploadFiles() async {
    if (videoFile == null) {
      showMessage(
        'Please select a video',
        isError: true,
      );
      return;
    }

    if (thumbnailFile == null) {
      showMessage(
        'Please select a thumbnail',
        isError: true,
      );
      return;
    }

    final String title = titleController.text.trim();

    final String description =
        descriptionController.text.trim();

    if (title.isEmpty) {
      showMessage(
        'Please enter video title',
        isError: true,
      );
      return;
    }

    if (description.isEmpty) {
      showMessage(
        'Please enter video description',
        isError: true,
      );
      return;
    }

    if (!isAdmin) {
      showMessage(
        'Only admin can upload videos',
        isError: true,
      );
      return;
    }

    if (isWindows) {
      showMessage(
        'Direct Drive upload is not available on Windows. Use the Android/web app or the Drive Agent.',
        isError: true,
      );
      return;
    }

    setState(() {
      isUploading = true;
      uploadStatus = 'Starting upload...';
    });

    try {
      final GoogleDriveService driveService =
          GoogleDriveService();

      final User? user =
          FirebaseAuth.instance.currentUser;

      // ========================================================
      // VIDEO UPLOAD
      // ========================================================

      setState(() {
        uploadStatus = 'Uploading video to Google Drive...';
      });

      final VideoUploadResult? videoResult =
          await driveService.uploadVideo(videoFile!);

      if (videoResult == null) {
        throw Exception(
          'Video upload failed',
        );
      }

      logger.info(
        'Video uploaded: ${videoResult.fileId}',
      );

      // ========================================================
      // THUMBNAIL UPLOAD
      // ========================================================

      setState(() {
        uploadStatus =
            'Uploading thumbnail to Google Drive...';
      });

      final VideoUploadResult? thumbnailResult =
          await driveService.uploadThumbnail(
        thumbnailFile!,
      );

      if (thumbnailResult == null) {
        throw Exception(
          'Thumbnail upload failed',
        );
      }

      logger.info(
        'Thumbnail uploaded: ${thumbnailResult.fileId}',
      );

      // ========================================================
      // FIRESTORE
      // ========================================================

      setState(() {
        uploadStatus =
            'Saving video information to Firestore...';
      });

      final DocumentReference<Map<String, dynamic>>
          firestoreDocument =
          await FirebaseFirestore.instance
              .collection('videos')
              .add({
        // -----------------------------
        // VIDEO
        // -----------------------------

        'fileId': videoResult.fileId,

        'videoUrl': videoResult.videoUrl,

        'fileName': videoResult.fileName,

        // -----------------------------
        // THUMBNAIL
        // -----------------------------

        'thumbnailFileId':
            thumbnailResult.fileId,

        'thumbnailUrl':
            thumbnailResult.videoUrl,

        'thumbnailFileName':
            thumbnailResult.fileName,

        // -----------------------------
        // INFORMATION
        // -----------------------------

        'title': title,

        'description': description,

        // -----------------------------
        // USER
        // -----------------------------

        'uploadedBy': user?.email,

        'uploadedByUid': user?.uid,

        // -----------------------------
        // DATE
        // -----------------------------

        'createdAt':
            FieldValue.serverTimestamp(),
      });

      logger.info(
        'Firestore document created: '
        '${firestoreDocument.id}',
      );

      // ========================================================
      // SUCCESS
      // ========================================================

      if (!mounted) {
        return;
      }

      setState(() {
        isUploading = false;

        uploadStatus =
            'Upload completed successfully!';
      });

      showMessage(
        'Video uploaded successfully!',
        isError: false,
      );

      // Clear fields
      setState(() {
        videoFile = null;
        thumbnailFile = null;
      });

      titleController.clear();
      descriptionController.clear();
    } catch (e, stackTrace) {
      logger.severe(
        'Upload error',
        e,
        stackTrace,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        isUploading = false;

        uploadStatus =
            'Upload failed: $e';
      });

      showMessage(
        'Upload failed:\n$e',
        isError: true,
      );
    }
  }

  // ============================================================
  // MESSAGE
  // ============================================================

  void showMessage(
    String message, {
    required bool isError,
  }) {
    if (!mounted) {
      return;
    }

    neoSnack(context, message, error: isError);
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    titleController.dispose();
    descriptionController.dispose();

    super.dispose();
  }

  // ============================================================
  // BUILD
  // ============================================================

  // ============================================================
  // UI HELPERS
  // ============================================================
  Widget _zone({
    required VoidCallback? onTap,
    required IconData icon,
    required String title,
    required String hint,
    required bool done,
    required double height,
    Widget? preview,
  }) {
    final c = done ? Neo.cyan : Neo.violet;
    return Tilt3D(
      onTap: onTap ?? () {},
      child: Container(
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: Neo.surface,
          border: Border.all(color: c.withValues(alpha: 0.45), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: c.withValues(alpha: 0.14),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (preview != null) preview,
            if (preview != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.65),
                    ],
                  ),
                ),
              ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.withValues(alpha: 0.16),
                        border: Border.all(color: c.withValues(alpha: 0.5)),
                        boxShadow: [
                          BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 18),
                        ],
                      ),
                      child: Icon(done ? Icons.check_rounded : icon, color: c, size: 28),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Neo.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      hint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: done ? Neo.cyan : Neo.muted,
                        fontFamily: Neo.mono,
                        fontSize: 11,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _flowRow(String from, String to, Color c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(from,
                style: const TextStyle(color: Neo.text, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          Icon(Icons.arrow_right_alt_rounded, color: c, size: 22),
          const SizedBox(width: 6),
          Expanded(flex: 5, child: Align(alignment: Alignment.centerLeft, child: NeoTag(to, color: c))),
        ],
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AdminService.notifier,
        builder: (c, _, __) => _page(c),
      );

  Widget _page(BuildContext context) {
    if (!isAdmin) {
      return const NeoScaffold(
        overline: 'Access // Restricted',
        title: 'Upload Video',
        body: EmptyState(
          icon: Icons.lock_outline_rounded,
          text: 'Admin access only',
          sub: 'Sign in with the admin account to upload videos.',
        ),
      );
    }

    final videoName = videoFile?.path.split(Platform.pathSeparator).last;

    return NeoScaffold(
      overline: 'Admin // Upload',
      title: 'Direct Upload',
      maxWidth: 720,
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
        children: [
          const SectionHeader(title: 'Video', tag: 'step 1', color: Neo.cyan),
          const SizedBox(height: 12),
          _zone(
            onTap: isUploading ? null : pickVideo,
            icon: Icons.video_library_rounded,
            title: videoName ?? 'Select Video',
            hint: videoFile == null ? 'TAP TO BROWSE' : 'VIDEO READY  //  TAP TO CHANGE',
            done: videoFile != null,
            height: 170,
          ),
          const SizedBox(height: 26),
          const SectionHeader(title: 'Thumbnail', tag: 'step 2', color: Neo.violet),
          const SizedBox(height: 12),
          _zone(
            onTap: isUploading ? null : pickThumbnail,
            icon: Icons.image_rounded,
            title: thumbnailFile == null ? 'Select Thumbnail' : 'Thumbnail selected',
            hint: thumbnailFile == null ? 'TAP TO BROWSE' : 'TAP TO CHANGE',
            done: thumbnailFile != null,
            height: 210,
            preview: thumbnailFile == null
                ? null
                : Image.file(
                    thumbnailFile!,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(height: 26),
          const SectionHeader(title: 'Details', tag: 'step 3', color: Neo.pink),
          const SizedBox(height: 14),
          NeoInput(
            controller: titleController,
            enabled: !isUploading,
            label: 'Video Title',
            hint: 'Enter video title',
            icon: Icons.title_rounded,
            action: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          NeoInput(
            controller: descriptionController,
            enabled: !isUploading,
            label: 'Video Information',
            hint: 'Enter video description / information',
            icon: Icons.notes_rounded,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
          ),
          const SizedBox(height: 24),
          GlassCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'UPLOAD PIPELINE',
                  style: TextStyle(
                    color: Neo.muted,
                    fontFamily: Neo.mono,
                    fontSize: 11,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 8),
                _flowRow('Video', 'GOOGLE DRIVE', Neo.cyan),
                _flowRow('Thumbnail', 'GOOGLE DRIVE', Neo.cyan),
                _flowRow('Title + Description', 'FIRESTORE', Neo.violet),
                _flowRow('Drive IDs + URLs', 'FIRESTORE', Neo.violet),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (uploadStatus.isNotEmpty) ...[
            GlassCard(
              padding: const EdgeInsets.all(14),
              borderColor: Neo.cyan.withValues(alpha: 0.35),
              child: isUploading
                  ? NeoProgress(value: null, label: uploadStatus)
                  : Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, color: Neo.cyan, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            uploadStatus,
                            style: const TextStyle(color: Neo.text, fontSize: 13.5),
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 18),
          ],
          NeoButton(
            label: isUploading ? 'UPLOADING...' : 'UPLOAD VIDEO',
            icon: Icons.cloud_upload_rounded,
            loading: isUploading,
            onTap: isUploading ? null : uploadFiles,
          ),
        ],
      ),
    );
  }
}
