import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/neo.dart';

class UploadVideoUrlPage extends StatefulWidget {
  const UploadVideoUrlPage({super.key});

  @override
  State<UploadVideoUrlPage> createState() => _UploadVideoUrlPageState();
}

class _UploadVideoUrlPageState extends State<UploadVideoUrlPage> {
  // ============================================================
  // ADMIN
  // ============================================================

  // ============================================================
  // FORM
  // ============================================================

  final _formKey = GlobalKey<FormState>();

  final TextEditingController _titleController =
      TextEditingController();

  final TextEditingController _episodesController =
      TextEditingController();

  final TextEditingController _seasonController =
      TextEditingController();

  final TextEditingController _videoUrlController =
      TextEditingController();

  final TextEditingController _thumbnailUrlController =
      TextEditingController();

  bool _isSaving = false;

  // ============================================================
  // CATEGORY
  // ============================================================

  String _selectedCategory = 'series';

  // ============================================================
  // ADMIN CHECK
  // ============================================================

  bool get isAdmin => AdminService.isAdmin;

  // ============================================================
  // GOOGLE DRIVE FILE ID
  // ============================================================

  String? _extractGoogleDriveFileId(String input) {
    final url = input.trim();

    if (url.isEmpty) {
      return null;
    }

    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();

      if (!host.contains('drive.google.com')) {
        return null;
      }

      // --------------------------------------------------------
      // /file/d/FILE_ID/view
      // --------------------------------------------------------

      final parts = uri.pathSegments;

      final fileIndex = parts.indexOf('file');

      if (fileIndex != -1 &&
          fileIndex + 2 < parts.length &&
          parts[fileIndex + 1] == 'd') {
        final fileId = parts[fileIndex + 2].trim();

        if (fileId.isNotEmpty) {
          return fileId;
        }
      }

      // --------------------------------------------------------
      // ?id=FILE_ID
      // --------------------------------------------------------

      final queryId = uri.queryParameters['id'];

      if (queryId != null && queryId.trim().isNotEmpty) {
        return queryId.trim();
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // CONVERT VIDEO URL
  // ============================================================

  String? _convertVideoUrl(String input) {
    final url = input.trim();

    if (url.isEmpty) {
      return null;
    }

    // ----------------------------------------------------------
    // GOOGLE DRIVE
    // ----------------------------------------------------------

    final fileId = _extractGoogleDriveFileId(url);

    if (fileId != null) {
      return 'https://drive.google.com/uc?export=download&id=$fileId';
    }

    // ----------------------------------------------------------
    // NORMAL HTTP / HTTPS URL
    // ----------------------------------------------------------

    try {
      final uri = Uri.parse(url);

      if (uri.hasScheme &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        return url;
      }
    } catch (_) {}

    return null;
  }

  // ============================================================
  // CONVERT THUMBNAIL URL
  // ============================================================

  String? _convertThumbnailUrl(String input) {
    final url = input.trim();

    if (url.isEmpty) {
      return '';
    }

    // ----------------------------------------------------------
    // GOOGLE DRIVE
    // ----------------------------------------------------------

    final fileId = _extractGoogleDriveFileId(url);

    if (fileId != null) {
      return 'https://drive.google.com/thumbnail'
          '?id=$fileId&sz=w800';
    }

    // ----------------------------------------------------------
    // NORMAL HTTP / HTTPS URL
    // ----------------------------------------------------------

    try {
      final uri = Uri.parse(url);

      if (uri.hasScheme &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        return url;
      }
    } catch (_) {}

    return null;
  }

  // ============================================================
  // SAVE VIDEO
  // ============================================================

  Future<void> _saveVideoUrl() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // ----------------------------------------------------------
    // ADMIN CHECK
    // ----------------------------------------------------------

    if (!isAdmin) {
      _showSnackBar(
        'Only admin can upload videos.',
        Colors.red,
      );

      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;

      // --------------------------------------------------------
      // ORIGINAL VIDEO URL
      // --------------------------------------------------------

      final String originalVideoUrl =
          _videoUrlController.text.trim();

      // --------------------------------------------------------
      // VIDEO URL
      // --------------------------------------------------------

      final String? videoUrl =
          _convertVideoUrl(originalVideoUrl);

      if (videoUrl == null) {
        throw Exception(
          'Invalid video URL or Google Drive URL.',
        );
      }

      // --------------------------------------------------------
      // THUMBNAIL
      // --------------------------------------------------------

      final String originalThumbnailUrl =
          _thumbnailUrlController.text.trim();

      final String? thumbnailUrl =
          _convertThumbnailUrl(originalThumbnailUrl);

      if (thumbnailUrl == null) {
        throw Exception(
          'Invalid thumbnail URL.',
        );
      }

      // --------------------------------------------------------
      // EPISODE
      //
      // 0 = field will NOT be stored in Firestore
      // 1+ = field will be stored
      // Negative = invalid
      // --------------------------------------------------------

      final int? episodes =
          int.tryParse(_episodesController.text.trim());

      if (episodes == null || episodes < 0) {
        throw Exception(
          'Invalid episode number.',
        );
      }

      // --------------------------------------------------------
      // SEASON
      //
      // 0 = field will NOT be stored in Firestore
      // 1+ = field will be stored
      // Negative = invalid
      // --------------------------------------------------------

      final int? season =
          int.tryParse(_seasonController.text.trim());

      if (season == null || season < 0) {
        throw Exception(
          'Invalid season number.',
        );
      }

      // --------------------------------------------------------
      // CATEGORY
      // --------------------------------------------------------

      final String category = _selectedCategory;

      // ========================================================
      // FIRESTORE DOCUMENT
      // ========================================================

      final videoDoc = FirebaseFirestore.instance
          .collection('videos')
          .doc();

      // ========================================================
      // BASIC DATA
      // ========================================================

      final Map<String, dynamic> videoData = {
        // ------------------------------------------------------
        // BASIC INFORMATION
        // ------------------------------------------------------

        'title': _titleController.text.trim(),

        // ------------------------------------------------------
        // CATEGORY
        // series / movies
        // ------------------------------------------------------

        'category': category,

        // ------------------------------------------------------
        // VIDEO URL
        // ------------------------------------------------------

        'videoUrl': videoUrl,

        // ------------------------------------------------------
        // THUMBNAIL
        // ------------------------------------------------------

        'thumbnailUrl': thumbnailUrl,

        // ------------------------------------------------------
        // ORIGINAL URL
        // ------------------------------------------------------

        'originalVideoUrl': originalVideoUrl,

        'originalThumbnailUrl': originalThumbnailUrl,

        // ------------------------------------------------------
        // UPLOAD TYPE
        // ------------------------------------------------------

        'uploadType': 'url',

        // ------------------------------------------------------
        // USER INFORMATION
        // ------------------------------------------------------

        'uploadedBy': user?.email ?? '',

        'uploadedByUid': user?.uid ?? '',

        // ------------------------------------------------------
        // TIMESTAMPS
        // ------------------------------------------------------

        'createdAt': FieldValue.serverTimestamp(),

        'updatedAt': FieldValue.serverTimestamp(),
      };

      // ========================================================
      // EPISODE
      //
      // IMPORTANT:
      // Episode = 0 என்றால் Firestore-ல் field உருவாகாது.
      // ========================================================

      if (episodes > 0) {
        videoData['episodes'] = episodes;
      }

      // Movies stay hidden until released from Manage Videos.
      if (category == 'movies') {
        videoData['released'] = false;
      }

      // ========================================================
      // SEASON
      //
      // IMPORTANT:
      // Season = 0 என்றால் Firestore-ல் field உருவாகாது.
      // ========================================================

      if (season > 0) {
        videoData['season'] = season;
      }

      // ========================================================
      // SAVE TO FIRESTORE
      // ========================================================

      await videoDoc.set(videoData);

      // ========================================================
      // CHECK MOUNTED
      // ========================================================

      if (!mounted) {
        return;
      }

      // ========================================================
      // SUCCESS MESSAGE
      // ========================================================

      _showSnackBar(
        'Video saved successfully!',
        Colors.green,
      );

      // ========================================================
      // CLEAR FORM
      // ========================================================

      _titleController.clear();
      _episodesController.clear();
      _seasonController.clear();
      _videoUrlController.clear();
      _thumbnailUrlController.clear();

      setState(() {
        _selectedCategory = 'series';
      });

      // ========================================================
      // CLOSE PAGE
      // ========================================================

      await Future.delayed(
        const Duration(milliseconds: 700),
      );

      if (!mounted) {
        return;
      }

      // Navigator.pop(context);
    } catch (e) {
      if (!mounted) {
        return;
      }

      _showSnackBar(
        'Failed to save video: $e',
        Colors.red,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  // ============================================================
  // SNACKBAR
  // ============================================================

  void _showSnackBar(
    String message,
    Color color,
  ) {
    if (!mounted) return;
    neoSnack(context, message, error: color == Colors.red);
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    bool isUrl = false,
    bool isNumber = false,
  }) {
    return NeoInput(
      controller: controller,
      label: label,
      hint: hint,
      icon: icon,
      maxLines: maxLines,
      keyboardType: keyboardType,
      enabled: !_isSaving,
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return '$label is required';
        }

        if (isNumber) {
          final int? number = int.tryParse(value.trim());

          if (number == null) {
            return 'Please enter a valid number';
          }

          if (number < 0) {
            return '$label cannot be negative';
          }
        }

        if (isUrl) {
          final uri = Uri.tryParse(value.trim());

          if (uri == null ||
              !uri.hasScheme ||
              (uri.scheme != 'http' && uri.scheme != 'https')) {
            return 'Please enter a valid URL';
          }
        }

        return null;
      },
    );
  }

  Widget _categorySelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'CONTENT TYPE',
          style: TextStyle(
            color: Neo.muted,
            fontFamily: Neo.mono,
            fontSize: 10.5,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 7),
        IgnorePointer(
          ignoring: _isSaving,
          child: NeoSegmented<String>(
            selected: _selectedCategory,
            onChanged: (v) => setState(() => _selectedCategory = v),
            options: const [
              NeoOpt('series', 'Series', Icons.tv_rounded),
              NeoOpt('movies', 'Movies', Icons.movie_rounded),
            ],
          ),
        ),
      ],
    );
  }

  Widget _group(String title, String tag, Color color, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title: title, tag: tag, color: color),
          const SizedBox(height: 14),
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            children[i],
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AdminService.notifier,
        builder: (c, _, __) => _page(c),
      );

  Widget _page(BuildContext context) {
    if (!isAdmin) {
      return const NeoScaffold(
        overline: 'Access // Restricted',
        title: 'Upload Using URL',
        body: EmptyState(
          icon: Icons.lock_outline_rounded,
          text: 'Only admin can access this page.',
        ),
      );
    }

    return NeoScaffold(
      overline: 'Admin // Link Upload',
      title: 'Upload Using URL',
      maxWidth: 720,
      body: Form(
        key: _formKey,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
          children: [
            const Text(
              'Enter video information and video URL.',
              style: TextStyle(color: Neo.muted, fontSize: 13.5),
            ),
            const SizedBox(height: 20),
            _group('Basic info', 'step 1', Neo.cyan, [
              _textField(
                controller: _titleController,
                label: 'Video Title',
                hint: 'Example: One Piece Episode 1',
                icon: Icons.title_rounded,
              ),
              _categorySelector(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _textField(
                      controller: _episodesController,
                      label: 'Episode',
                      hint: 'e.g. 1',
                      icon: Icons.video_library_outlined,
                      keyboardType: TextInputType.number,
                      isNumber: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _textField(
                      controller: _seasonController,
                      label: 'Season',
                      hint: 'e.g. 1',
                      icon: Icons.layers_outlined,
                      keyboardType: TextInputType.number,
                      isNumber: true,
                    ),
                  ),
                ],
              ),
            ]),
            _group('Media links', 'step 2', Neo.violet, [
              _textField(
                controller: _videoUrlController,
                label: 'Video URL',
                hint: 'Paste Google Drive or direct video URL',
                icon: Icons.link_rounded,
                keyboardType: TextInputType.url,
                isUrl: true,
              ),
              _textField(
                controller: _thumbnailUrlController,
                label: 'Thumbnail URL',
                hint: 'Paste image URL or Google Drive URL',
                icon: Icons.image_outlined,
                keyboardType: TextInputType.url,
                isUrl: true,
              ),
            ]),
            GlassCard(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded, color: Neo.cyan, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Content Type: '
                      '${_selectedCategory == 'series' ? 'Series' : 'Movies'}\n\n'
                      'Episode or Season = 0 means '
                      'that field will not be stored in Firestore.\n\n'
                      'Google Drive video and thumbnail URLs '
                      'are converted automatically.',
                      style: const TextStyle(
                        color: Neo.muted,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            NeoButton(
              label: _isSaving ? 'SAVING...' : 'SAVE VIDEO',
              icon: Icons.cloud_upload_rounded,
              loading: _isSaving,
              onTap: _isSaving ? null : _saveVideoUrl,
            ),
            const SizedBox(height: 14),
            const Center(
              child: Text(
                'Data saved in Firestore → videos collection',
                style: TextStyle(
                  color: Neo.muted,
                  fontFamily: Neo.mono,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _episodesController.dispose();
    _seasonController.dispose();
    _videoUrlController.dispose();
    _thumbnailUrlController.dispose();
    super.dispose();
  }
}