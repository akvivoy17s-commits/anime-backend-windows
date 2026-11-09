import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/neo.dart';
import '../services/stream_perf.dart';
import 'video_play.dart';

class PlaylistVideosPage extends StatefulWidget {
  final String playlistId;
  final String playlistName;

  const PlaylistVideosPage({
    super.key,
    required this.playlistId,
    required this.playlistName,
  });

  @override
  State<PlaylistVideosPage> createState() => _PlaylistVideosPageState();
}

class _PlaylistVideosPageState extends State<PlaylistVideosPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // cached so rebuilds never re-trigger the Firestore reads
  late Future<List<DocumentSnapshot<Map<String, dynamic>>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadPlaylistVideos();
  }

  void _reload() {
    setState(() => _future = _loadPlaylistVideos());
  }

  // ===========================================================
  // LOAD PLAYLIST VIDEOS
  // ===========================================================

  Future<List<DocumentSnapshot<Map<String, dynamic>>>>
      _loadPlaylistVideos() async {
    final playlistDoc = await _firestore
        .collection('playlists')
        .doc(widget.playlistId)
        .get();

    List<String> videoIds = [];

    // =========================================================
    // METHOD 1
    // playlists/{playlistId}.videoIds
    // =========================================================

    if (playlistDoc.exists) {
      final data = playlistDoc.data();

      if (data != null && data['videoIds'] is List) {
        videoIds = (data['videoIds'] as List)
            .map((e) => e.toString())
            .where((id) => id.isNotEmpty)
            .toList();
      }
    }

    // =========================================================
    // METHOD 2
    // playlists/{playlistId}/videos/{videoId}
    // =========================================================

    if (videoIds.isEmpty) {
      final subCollection = await _firestore
          .collection('playlists')
          .doc(widget.playlistId)
          .collection('videos')
          .get();

      videoIds = subCollection.docs
          .map((doc) => doc.id)
          .toList();
    }

    if (videoIds.isEmpty) {
      return [];
    }

    // =========================================================
    // GET VIDEO DOCUMENTS
    // =========================================================

    final List<DocumentSnapshot<Map<String, dynamic>>> videos = [];

    for (int i = 0; i < videoIds.length; i += 30) {
      final int end =
          (i + 30 > videoIds.length) ? videoIds.length : i + 30;

      final chunk = videoIds.sublist(i, end);

      final result = await _firestore
          .collection('videos')
          .where(
            FieldPath.documentId,
            whereIn: chunk,
          )
          .get();

      videos.addAll(result.docs);
    }

    // =========================================================
    // SORT BY EPISODE NUMBER ASCENDING
    //
    // Example:
    // Episode 1
    // Episode 2
    // Episode 3
    // ...
    // Episode 10
    // Episode 11
    // =========================================================

    videos.sort((a, b) {
      final aData = a.data() ?? {};
      final bData = b.data() ?? {};

      // season first, then episode
      final bySeason = _getSeasonNumber(aData).compareTo(_getSeasonNumber(bData));
      if (bySeason != 0) return bySeason;
      return _getEpisodeNumber(aData).compareTo(_getEpisodeNumber(bData));
    });

    // get the first episodes' stream links ready while the user looks at the list
    unawaited(StreamWarm.fromDocs(videos.map((d) => d.data())));

    // Episode 1: build a fully initialized player NOW, so tapping it starts playing instantly.
    if (videos.isNotEmpty) {
      _firstId = videos.first.id;
      final url = _videoUrlOf(videos.first.data() ?? {});
      if (url.isNotEmpty) {
        unawaited(StreamPreload.prepare(url, StreamCandidates.build(url)));
      }
    }

    return videos;
  }

  String? _firstId; // first (lowest episode) video of this playlist

  String _videoUrlOf(Map<String, dynamic> d) {
    for (final k in const ['videoUrl', 'url', 'videoURL']) {
      final v = (d[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  @override
  void dispose() {
    // leaving the playlist without playing -> free the prepared player
    StreamPreload.clear();
    super.dispose();
  }

  // ===========================================================
  // GET THUMBNAIL
  // ===========================================================

  String _getThumbnailUrl(Map<String, dynamic> data) {
    String thumbnail = '';

    final possibleFields = [
      'thumbnailUrl',
      'thumbnail',
      'imageUrl',
      'posterUrl',
    ];

    for (final field in possibleFields) {
      final value = data[field];

      if (value != null &&
          value.toString().trim().isNotEmpty) {
        thumbnail = value.toString().trim();
        break;
      }
    }

    if (thumbnail.isEmpty) {
      return '';
    }

    final driveFileId = _extractDriveFileId(thumbnail);

    if (driveFileId != null) {
      return 'https://drive.google.com/thumbnail'
          '?id=$driveFileId'
          '&sz=w800';
    }

    return thumbnail;
  }

  // ===========================================================
  // EXTRACT GOOGLE DRIVE FILE ID
  // ===========================================================

  String? _extractDriveFileId(String url) {
    final cleanUrl = url.trim();

    final fileRegex = RegExp(
      r'drive\.google\.com/file/d/([^/?#]+)',
    );

    final fileMatch = fileRegex.firstMatch(cleanUrl);

    if (fileMatch != null) {
      return fileMatch.group(1);
    }

    final uri = Uri.tryParse(cleanUrl);

    if (uri != null) {
      final id = uri.queryParameters['id'];

      if (id != null && id.isNotEmpty) {
        return id;
      }
    }

    return null;
  }

  // ===========================================================
  // GET TITLE
  // ===========================================================

  String _getTitle(Map<String, dynamic> data) {
    final possibleFields = [
      'title',
      'name',
      'videoTitle',
    ];

    for (final field in possibleFields) {
      final value = data[field];

      if (value != null &&
          value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }

    return 'Untitled Video';
  }

  // ===========================================================
  // GET SEASON (stored in Firestore as `season`)
  // ===========================================================

  String _getSeason(Map<String, dynamic> data) {
    for (final field in const ['season', 'seasonNumber']) {
      final value = data[field];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    return '';
  }

  int _getSeasonNumber(Map<String, dynamic> data) {
    final m = RegExp(r'\d+').firstMatch(_getSeason(data));
    return m == null ? 0 : (int.tryParse(m.group(0)!) ?? 0);
  }

  // ===========================================================
  // GET EPISODE TEXT
  // ===========================================================

  String _getEpisode(Map<String, dynamic> data) {
    final possibleFields = [
      'episodes',
      'episodeNumber',
      'episode',
      'episodeNo',
      'ep',
    ];

    for (final field in possibleFields) {
      final value = data[field];

      if (value != null &&
          value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }

    return '';
  }

  // ===========================================================
  // GET EPISODE NUMBER FOR SORTING
  //
  // Handles:
  // 1
  // "1"
  // "Episode 1"
  // "episode 10"
  // ===========================================================

  int _getEpisodeNumber(Map<String, dynamic> data) {
    final episode = _getEpisode(data);

    if (episode.isEmpty) {
      return 999999;
    }

    // Extract first number from the episode value.
    //
    // Examples:
    // "1"          -> 1
    // "10"         -> 10
    // "Episode 5"  -> 5
    // "episode 12" -> 12

    final match = RegExp(r'\d+').firstMatch(episode);

    if (match != null) {
      return int.tryParse(match.group(0)!) ?? 999999;
    }

    return 999999;
  }

  // ===========================================================
  // BUILD
  // ===========================================================

  @override
  Widget build(BuildContext context) {
    return NeoScaffold(
      overline: 'Playlist // Episodes',
      title: widget.playlistName,
      maxWidth: 1000,
      body: FutureBuilder<List<DocumentSnapshot<Map<String, dynamic>>>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              itemCount: 5,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, __) => ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: const SizedBox(height: 108, child: Shimmer()),
              ),
            );
          }

          if (snapshot.hasError) {
            return ErrorState(
              text: 'Unable to load videos',
              onRetry: _reload,
            );
          }

          final videos = snapshot.data ?? [];
          if (videos.isEmpty) {
            return const EmptyState(
              icon: Icons.video_library_outlined,
              text: 'No videos in this playlist',
              sub: 'Add episodes from Manage Videos.',
            );
          }

          return RefreshIndicator(
            color: Neo.cyan,
            backgroundColor: Neo.surface,
            onRefresh: () async {
              _reload();
              await _future;
            },
            child: GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 520,
                mainAxisExtent: 112,
                crossAxisSpacing: 14,
                mainAxisSpacing: 12,
              ),
              itemCount: videos.length,
              itemBuilder: (context, index) {
                final doc = videos[index];
                final data = doc.data() ?? {};
                return FadeIn(
                  index: index,
                  child: _videoCard(
                    videoId: doc.id,
                    title: _getTitle(data),
                    season: _getSeason(data),
                    episode: _getEpisode(data),
                    thumbnail: _getThumbnailUrl(data),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  // ===========================================================
  // VIDEO CARD
  // ===========================================================
  Widget _videoCard({
    required String videoId,
    required String title,
    required String season,
    required String episode,
    required String thumbnail,
  }) {
    return Tilt3D(
      onTap: () {
        // another episode chosen -> the prepared first-episode player is not needed
        if (videoId != _firstId) StreamPreload.clear();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoPlayPage(
              videoId: videoId,
              playlistId: widget.playlistId,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Neo.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Neo.line),
          boxShadow: [
            BoxShadow(
              color: Neo.violet.withValues(alpha: 0.10),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    thumbnail.isEmpty
                        ? const ColoredBox(
                            color: Neo.bg2,
                            child: Icon(Icons.movie_outlined, color: Neo.muted),
                          )
                        : NeoImage(thumbnail),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                    ),
                    Center(
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Neo.cyan.withValues(alpha: 0.9),
                          boxShadow: [
                            BoxShadow(
                              color: Neo.cyan.withValues(alpha: 0.5),
                              blurRadius: 14,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Neo.bg, size: 22),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (season.isNotEmpty || episode.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (season.isNotEmpty) NeoTag('SEASON $season', color: Neo.violet),
                        if (episode.isNotEmpty) NeoTag('EP $episode', color: Neo.cyan),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Neo.text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Neo.muted),
          ],
        ),
      ),
    );
  }
}
