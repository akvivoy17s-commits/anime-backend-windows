import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../services/drive_agent_service.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/neo.dart';
import '../ui/refresh.dart';
import 'video_play.dart';

class ManageVideoPage extends StatefulWidget {
  const ManageVideoPage({super.key});

  @override
  State<ManageVideoPage> createState() => _ManageVideoPageState();
}

class _ManageVideoPageState extends State<ManageVideoPage>
    with SingleTickerProviderStateMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Streams are created ONCE. Creating them inside build() gave a brand-new
  // stream on every setState (select / search), so StreamBuilder went back to
  // "waiting" and showed the skeleton again = the "whole page reload".
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _videosStream =
      _firestore
          .collection('videos')
          .orderBy('createdAt', descending: true)
          .snapshots();

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _allVideosStream =
      _firestore.collection('videos').snapshots();

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _playlistsStream =
      _firestore
          .collection('playlists')
          .orderBy('createdAt', descending: true)
          .snapshots();

  late TabController _tabController;

  final Color backgroundColor = Neo.bg;

  final Color cardColor = Neo.surface;

  final Color secondaryCardColor = const Color(0xFF1B2040);

  final Color accentColor = Neo.cyan;

  // =========================================================
  // SEARCH
  // =========================================================

  final TextEditingController _videoSearchController = TextEditingController();

  final TextEditingController _playlistSearchController =
      TextEditingController();

  String _videoSearchText = '';

  String _playlistSearchText = '';

  // =========================================================
  // MULTI-SELECT (Videos tab)
  // =========================================================

  final Set<String> _selectedIds = {};

  bool _bulkDeleting = false;

  bool _bulkEditing = false;

  // latest videos seen by the list (id -> data), used by bulk edit
  Map<String, Map<String, dynamic>> _docCache = {};

  bool _selMode = false; // checkboxes visible even before the first pick

  bool get _selecting => _selMode || _selectedIds.isNotEmpty;

  void _exitSelect() => setState(() {
        _selectedIds.clear();
        _selMode = false;
      });

  // =========================================================
  // INIT
  // =========================================================

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();

    _videoSearchController.dispose();
    _playlistSearchController.dispose();

    super.dispose();
  }

  // =========================================================
  // DRIVE THUMBNAIL
  // =========================================================

  String _getDriveThumbnailUrl(String url) {
    final value = url.trim();

    if (value.isEmpty) {
      return '';
    }

    final match = RegExp(r'(?:id=|/d/)([a-zA-Z0-9_-]+)').firstMatch(value);

    if (match != null) {
      return 'https://drive.google.com/thumbnail?id=${match.group(1)}&sz=w500';
    }

    return value;
  }

  // =========================================================
  // IMAGE PLACEHOLDER
  // =========================================================

  Widget _imagePlaceholder({double width = 80, double height = 80}) {
    return Container(
      width: width,
      height: height,
      color: secondaryCardColor,
      child: const Icon(Icons.movie_outlined, color: Neo.muted, size: 28),
    );
  }

  // =========================================================
  // NUMERIC PARSER
  // =========================================================

  int _getNumber(dynamic value) {
    final text = value?.toString() ?? '';

    final match = RegExp(r'\d+').firstMatch(text);

    if (match != null) {
      return int.tryParse(match.group(0)!) ?? 999999;
    }

    return 999999;
  }

  // =========================================================
  // EPISODE NUMBER
  // =========================================================

  int _getEpisodeNumber(dynamic value) {
    return _getNumber(value);
  }

  // =========================================================
  // SMART SEARCH (title / category + season / episode numbers)
  //
  //   "naruto"            -> title / category
  //   "s2" / "season 2"   -> season 2 only
  //   "ep5" / "episode 5" -> episode 5 only
  //   "s2e5" / "s2 ep5"   -> season 2, episode 5
  //   "naruto s2 ep5"     -> all of the above together
  //   "5"                 -> season == 5 OR episode == 5 (exact, so "5"
  //                          no longer matches 15 / 25 ...)
  // =========================================================

  static final RegExp _seasonQuery =
      RegExp(r'(?:^|\s)(?:season|s)\s*0*(\d+)(?=e|\s|$)');

  static final RegExp _episodeQuery =
      RegExp(r'(?:^|\s)(?:episode|ep|e)\.?\s*0*(\d+)(?=\s|$)');

  static const Set<String> _searchNoise = {'season', 'episode', 'ep', 's', 'e'};

  bool _matchesVideoSearch(Map<String, dynamic> data, String rawQuery) {
    var q = rawQuery.toLowerCase().trim();
    if (q.isEmpty) return true;

    final title = (data['title'] ?? '').toString().toLowerCase();
    final category = (data['category'] ?? '').toString().toLowerCase();
    final seasonNo = _getNumber(data['season']);
    final episodeNo = _getEpisodeNumber(data['episodes']);

    // Season filter: s2 / s02 / season 2
    final sm = _seasonQuery.firstMatch(q);
    if (sm != null) {
      final want = int.tryParse(sm.group(1)!);
      if (want == null || want != seasonNo) return false;
      q = q.replaceRange(sm.start, sm.end, ' ');
    }

    // Episode filter: e5 / ep5 / ep 5 / episode 5
    final em = _episodeQuery.firstMatch(q);
    if (em != null) {
      final want = int.tryParse(em.group(1)!);
      if (want == null || want != episodeNo) return false;
      q = q.replaceRange(em.start, em.end, ' ');
    }

    // Whatever is left: every word must match (title / category / number)
    for (final token in q.split(RegExp(r'\s+'))) {
      if (token.isEmpty || _searchNoise.contains(token)) continue;

      if (RegExp(r'^\d+$').hasMatch(token)) {
        final n = int.tryParse(token);
        final whole = RegExp('(?<!\\d)${RegExp.escape(token)}(?!\\d)');
        final ok = n == seasonNo ||
            n == episodeNo ||
            whole.hasMatch(title) ||
            whole.hasMatch(category);
        if (!ok) return false;
      } else if (!title.contains(token) && !category.contains(token)) {
        return false;
      }
    }

    return true;
  }

  // =========================================================
  // SORT VIDEOS
  // =========================================================

  void _sortVideosBySeasonAndEpisode(List<Map<String, dynamic>> videos) {
    videos.sort((a, b) {
      final seasonA = _getNumber(a['season']);

      final seasonB = _getNumber(b['season']);

      if (seasonA != seasonB) {
        return seasonA.compareTo(seasonB);
      }

      final episodeA = _getEpisodeNumber(a['episodes']);

      final episodeB = _getEpisodeNumber(b['episodes']);

      if (episodeA != episodeB) {
        return episodeA.compareTo(episodeB);
      }

      final titleA = (a['title'] ?? '').toString().toLowerCase();

      final titleB = (b['title'] ?? '').toString().toLowerCase();

      return titleA.compareTo(titleB);
    });
  }

  // =========================================================
  // GROUP: ANIME (category) -> SEASON -> EPISODE
  // Latest uploaded anime first, latest uploaded season first, episodes in EP order.
  // =========================================================

  static const String _noAnime = 'Uncategorized';

  /// Episode number as a number ("5", "EP 05", "12.5" -> 5, 5, 12.5). No number = last.
  double _episodeValue(dynamic value) {
    if (value is num) return value.toDouble();
    final m = RegExp(r'\d+(?:\.\d+)?').firstMatch(value?.toString() ?? '');
    return m == null ? double.infinity : (double.tryParse(m.group(0)!) ?? double.infinity);
  }

  int _createdMs(Map<String, dynamic> d) {
    final v = d['createdAt'];
    return v is Timestamp ? v.millisecondsSinceEpoch : 9007199254740991;
  }

  /// Episodes inside a season are ALWAYS in episode order, highest first (EP 12, 11, ... 2, 1),
  /// whatever order they were uploaded in. Videos without an episode number go last.
  int _compareEpisodes(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ea = _episodeValue(a['episodes']);
    final eb = _episodeValue(b['episodes']);
    if (ea.isInfinite != eb.isInfinite) return ea.isInfinite ? 1 : -1; // no number = last
    final c = eb.compareTo(ea); // descending
    if (c != 0) return c;
    final t = _createdMs(b).compareTo(_createdMs(a)); // same number: newer upload first
    if (t != 0) return t;
    return (a['title'] ?? '').toString().toLowerCase().compareTo((b['title'] ?? '').toString().toLowerCase());
  }

  DateTime _createdOf(Map<String, dynamic> d) {
    final v = d['createdAt'];
    if (v is Timestamp) return v.toDate();
    return DateTime.now(); // null = just uploaded, server time still pending
  }

  /// Flat list for ListView.builder: [_GroupHeader | video doc, ...]
  /// Order: anime (latest upload first) -> season (latest upload first)
  /// -> episodes.
  List<Object> _buildGroupedItems(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final groups = <String,
        Map<int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>>{};
    final names = <String, String>{};
    final animeLatest = <String, DateTime>{};
    final seasonLatest = <String, Map<int, DateTime>>{};

    for (final doc in docs) {
      final data = doc.data();
      // One group per ANIME = its title ("category" is only series/movies, not the anime).
      final raw = (data['title'] ?? '').toString().trim().replaceAll(RegExp(r'\s+'), ' ');
      final name = raw.isEmpty ? _noAnime : raw;
      final key = name.toLowerCase();
      final season = _getNumber(data['season']);
      final t = _createdOf(data);

      names.putIfAbsent(key, () => name);
      groups.putIfAbsent(key, () => {}).putIfAbsent(season, () => []).add(doc);

      final a = animeLatest[key];
      if (a == null || t.isAfter(a)) animeLatest[key] = t;

      final sl = seasonLatest.putIfAbsent(key, () => {});
      final s = sl[season];
      if (s == null || t.isAfter(s)) sl[season] = t;
    }

    final noAnimeKey = _noAnime.toLowerCase();
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a == noAnimeKey) return 1; // Uncategorized always last
        if (b == noAnimeKey) return -1;
        return animeLatest[b]!.compareTo(animeLatest[a]!); // newest first
      });

    final items = <Object>[];

    for (final key in keys) {
      final seasons = groups[key]!;
      final total = seasons.values.fold<int>(0, (n, l) => n + l.length);

      items.add(_GroupHeader(names[key]!, count: total, isAnime: true));

      final seasonKeys = seasons.keys.toList()
        ..sort((a, b) {
          if (a == 999999) return 1; // "No Season" last
          if (b == 999999) return -1;
          return seasonLatest[key]![b]!.compareTo(seasonLatest[key]![a]!);
        });

      for (final season in seasonKeys) {
        // movies / single-season-less titles: no pointless "No Season" header
        if (!(season == 999999 && seasonKeys.length == 1)) {
          items.add(
            _GroupHeader(season == 999999 ? 'No Season' : 'Season $season'),
          );
        }

        final list = seasons[season]!..sort((a, b) => _compareEpisodes(a.data(), b.data()));

        items.addAll(list);
      }
    }

    return items;
  }

  Widget _groupHeader(_GroupHeader h) {
    if (h.isAnime) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(
          children: [
            const Icon(Icons.movie_filter_rounded, color: Neo.cyan, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                h.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Neo.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            NeoTag('${h.count} VIDEO${h.count == 1 ? '' : 'S'}',
                color: Neo.cyan),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: Neo.amber,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            h.title.toUpperCase(),
            style: const TextStyle(
              color: Neo.amber,
              fontFamily: Neo.mono,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================
  // GET ASSIGNED VIDEO IDS
  // =========================================================

  Future<Set<String>> getAssignedVideoIds() async {
    final snapshot = await _firestore.collection('playlists').get();

    final Set<String> assignedIds = {};

    for (final doc in snapshot.docs) {
      final data = doc.data();

      final ids = data['videoIds'];

      if (ids is List) {
        for (final id in ids) {
          final value = id.toString().trim();

          if (value.isNotEmpty) {
            assignedIds.add(value);
          }
        }
      }
    }

    return assignedIds;
  }

  // =========================================================
  // ADD MULTIPLE VIDEOS
  // =========================================================

  /// Movies are stand-alone titles: they can never be put inside a playlist.
  bool _isMovieData(Map<String, dynamic>? data) {
    final c = (data?['category'] ?? '').toString().trim().toLowerCase();
    return c == 'movies' || c == 'movie';
  }

  Future<int> addMultipleVideosToPlaylist(
    String playlistId,
    List<String> videoIds,
  ) async {
    if (videoIds.isEmpty) {
      return 0;
    }

    final assignedIds = await getAssignedVideoIds();

    // safety net: drop movies even if one slipped into the selection
    final movieIds = <String>{};
    await Future.wait(videoIds.map((id) async {
      try {
        final d = await _firestore.collection('videos').doc(id).get();
        if (_isMovieData(d.data())) movieIds.add(id);
      } catch (_) {}
    }));

    final safeVideoIds = videoIds.where((id) {
      return !assignedIds.contains(id) && !movieIds.contains(id);
    }).toList();

    if (safeVideoIds.isEmpty) {
      return 0;
    }

    await _firestore.collection('playlists').doc(playlistId).update({
      'videoIds': FieldValue.arrayUnion(safeVideoIds),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    return safeVideoIds.length;
  }

  // =========================================================
  // REMOVE MULTIPLE VIDEOS
  // =========================================================

  Future<void> removeMultipleVideosFromPlaylist(
    String playlistId,
    List<String> videoIds,
  ) async {
    if (videoIds.isEmpty) {
      return;
    }

    await _firestore.collection('playlists').doc(playlistId).update({
      'videoIds': FieldValue.arrayRemove(videoIds),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // =========================================================
  // DELETE VIDEO
  // =========================================================

  /// Video/Drive URLs stored on a video document (used to clear Drive Agent records).
  List<String> _driveUrlsOf(Map<String, dynamic>? d) {
    if (d == null) return const [];
    return {
      for (final k in const ['originalVideoUrl', 'videoUrl'])
        if (d[k] is String && (d[k] as String).trim().isNotEmpty)
          (d[k] as String).trim(),
    }.toList();
  }

  Future<void> deleteVideo(String videoId) async {
    try {
      final playlistsSnapshot = await _firestore.collection('playlists').get();

      for (final playlist in playlistsSnapshot.docs) {
        final data = playlist.data();
        final ids = data['videoIds'];

        if (ids is List && ids.contains(videoId)) {
          await playlist.reference.update({
            'videoIds': FieldValue.arrayRemove([videoId]),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }

      final snap = await _firestore.collection('videos').doc(videoId).get();
      final urls = _driveUrlsOf(snap.data());

      await _firestore.collection('videos').doc(videoId).delete();

      // Drive Agent must forget this video too (best-effort, never blocks).
      unawaited(DriveAgentService.forget(videoIds: [videoId], urls: urls));

      if (!mounted) return;

      neoSnack(context, 'Video deleted successfully');
    } catch (e) {
      showError('Failed to delete video: $e');
    }
  }

  // =========================================================
  // OPEN / PLAY
  // =========================================================

  bool _opening = false;

  Future<void> _openVideo(String videoId) async {
    if (_opening) return;
    _opening = true;
    try {
      var playlistId = '';
      try {
        final pl = await _firestore
            .collection('playlists')
            .where('videoIds', arrayContains: videoId)
            .limit(1)
            .get();
        if (pl.docs.isNotEmpty) playlistId = pl.docs.first.id;
      } catch (_) {}
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayPage(videoId: videoId, playlistId: playlistId),
        ),
      );
    } finally {
      _opening = false;
    }
  }

  // =========================================================
  // RELEASE (movies stay hidden until released)
  // =========================================================

  Future<void> _releaseMovie(String videoId, String title) async {
    final ok = await neoConfirm(
      context,
      title: 'Release Movie?',
      message: '"$title" ippo Movies page, Home, Search-la ellarukkum theriyum.',
      confirmLabel: 'RELEASE',
    );
    if (!ok) return;
    try {
      await _firestore.collection('videos').doc(videoId).update({
        'released': true,
        'releasedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      neoSnack(context, 'Movie released');
    } catch (e) {
      showError('Release failed: $e');
    }
  }

  Future<void> _unreleaseMovie(String videoId, String title) async {
    final ok = await neoConfirm(
      context,
      title: 'Unrelease Movie?',
      message: '"$title" Movies page, Home, Search-la irundhu maraiyum. '
          'Marupadiyum Release pannum varai yaarukkum theriyaadhu.',
      confirmLabel: 'UNRELEASE',
      danger: true,
    );
    if (!ok) return;
    try {
      await _firestore.collection('videos').doc(videoId).update({
        'released': false,
        'releasedAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      neoSnack(context, 'Movie unreleased');
    } catch (e) {
      showError('Unrelease failed: $e');
    }
  }

  Future<void> confirmDeleteVideo(String videoId, String title) async {
    final ok = await neoConfirm(
      context,
      title: 'Delete Video?',
      message: 'Delete "$title"?\n\n'
          'If this video is inside playlists, '
          'it will also be removed from those playlists.',
      confirmLabel: 'DELETE',
      danger: true,
    );

    if (ok) {
      await deleteVideo(videoId);
    }
  }

  // =========================================================
  // BULK DELETE
  // =========================================================

  void _toggleSelected(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  /// Same cleanup as [deleteVideo], for many videos: first remove the ids from
  /// every playlist that holds them, then delete the video documents.
  /// Writes are chunked (Firestore batch limit is 500 operations).
  Future<void> deleteVideosBulk(Set<String> ids) async {
    if (ids.isEmpty || _bulkDeleting) return;

    setState(() => _bulkDeleting = true);

    try {
      final playlists = await _firestore.collection('playlists').get();

      var batch = _firestore.batch();
      var ops = 0;

      Future<void> flush() async {
        if (ops == 0) return;
        await batch.commit();
        batch = _firestore.batch();
        ops = 0;
      }

      for (final playlist in playlists.docs) {
        final raw = playlist.data()['videoIds'];
        if (raw is! List) continue;

        final hit = raw.map((e) => e.toString()).where(ids.contains).toList();
        if (hit.isEmpty) continue;

        batch.update(playlist.reference, {
          'videoIds': FieldValue.arrayRemove(hit),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        if (++ops >= 400) await flush();
      }

      await flush(); // playlists are clean before any video disappears

      // Collect Drive URLs first (docs vanish after the delete below).
      final urls = <String>[];
      final idList = ids.toList();
      for (var i = 0; i < idList.length; i += 30) {
        final q = await _firestore
            .collection('videos')
            .where(FieldPath.documentId, whereIn: idList.skip(i).take(30).toList())
            .get();
        for (final d in q.docs) {
          urls.addAll(_driveUrlsOf(d.data()));
        }
      }

      for (final id in ids) {
        batch.delete(_firestore.collection('videos').doc(id));
        if (++ops >= 400) await flush();
      }

      await flush();

      unawaited(DriveAgentService.forget(videoIds: idList, urls: urls));

      if (!mounted) return;

      setState(() {
        _selectedIds.clear();
        _selMode = false;
      });

      neoSnack(context, '${ids.length} video(s) deleted successfully');
    } catch (e) {
      showError('Failed to delete videos: $e');
    } finally {
      if (mounted) setState(() => _bulkDeleting = false);
    }
  }

  Future<void> confirmDeleteSelected() async {
    final ids = Set<String>.from(_selectedIds);
    if (ids.isEmpty) return;

    final ok = await neoConfirm(
      context,
      title: 'Delete ${ids.length} Video(s)?',
      message: 'Delete ${ids.length} selected video(s)?\n\n'
          'They will also be removed from any playlists they are in. '
          'This cannot be undone.',
      confirmLabel: 'DELETE ${ids.length}',
      danger: true,
    );

    if (ok) await deleteVideosBulk(ids);
  }

  // ---------------------------------------------------------
  // BULK EDIT (same change for every selected video)
  // ---------------------------------------------------------
  Future<void> _bulkEditSelected() async {
    if (_selectedIds.isEmpty || _bulkDeleting || _bulkEditing) return;

    final ids = Set<String>.from(_selectedIds);

    final r = await showNeoSheet<Map<String, String>>(
      context,
      title: 'Edit ${ids.length} videos',
      sub: 'same change for all',
      child: const _BulkVideoEditForm(),
    );

    if (r == null || !mounted) return;

    setState(() => _bulkEditing = true);

    try {
      final find = r['find'] ?? '';
      final sameTitle = r['title'] ?? '';

      var batch = _firestore.batch();
      var ops = 0;
      var changed = 0;
      var titleHits = 0;

      Future<void> flush() async {
        if (ops == 0) return;
        await batch.commit();
        batch = _firestore.batch();
        ops = 0;
      }

      for (final id in ids) {
        final data = _docCache[id] ?? const <String, dynamic>{};
        final upd = <String, dynamic>{};

        if (find.isNotEmpty) {
          final old = (data['title'] ?? '').toString();
          final t = old.replaceAll(find, r['replace'] ?? '').trim();
          if (t.isNotEmpty && t != old) {
            upd['title'] = t;
            titleHits++;
          }
        }

        if (sameTitle.isNotEmpty) upd['title'] = sameTitle;

        if ((r['category'] ?? '').isNotEmpty) upd['category'] = r['category'];
        if ((r['season'] ?? '').isNotEmpty) {
          upd['season'] = int.parse(r['season']!);
        }
        if ((r['episode'] ?? '').isNotEmpty) {
          upd['episodes'] = int.parse(r['episode']!);
        }
        if ((r['video_url'] ?? '').isNotEmpty) upd['videoUrl'] = r['video_url'];
        if ((r['thumbnail_url'] ?? '').isNotEmpty) {
          upd['thumbnailUrl'] = r['thumbnail_url'];
        }
        if ((r['description'] ?? '').isNotEmpty) {
          upd['description'] = r['description'];
        }

        if (upd.isEmpty) continue;

        upd['updatedAt'] = FieldValue.serverTimestamp();
        batch.update(_firestore.collection('videos').doc(id), upd);
        changed++;
        if (++ops >= 400) await flush();
      }

      await flush();

      if (!mounted) return;

      if (changed == 0) {
        showError('"$find" was not found in the selected titles. '
            'Copy the text exactly as shown.');
        return;
      }

      setState(() {
        _selectedIds.clear();
        _selMode = false;
      });

      neoSnack(
        context,
        '$changed video(s) updated'
        '${find.isNotEmpty ? ' (title changed in $titleHits)' : ''}',
      );
    } catch (e) {
      showError('Failed to update videos: $e');
    } finally {
      if (mounted) setState(() => _bulkEditing = false);
    }
  }

  Widget _selectionBar(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final allIds = docs.map((d) => d.id).toSet();
    final all = allIds.isNotEmpty && allIds.every(_selectedIds.contains);
    final busy = _bulkDeleting || _bulkEditing;
    final none = _selectedIds.isEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _selectAllRow(
            all: all,
            disabled: busy,
            count: _selectedIds.length,
            onToggle: () => setState(() {
              if (all) {
                _selectedIds.removeAll(allIds);
              } else {
                _selectedIds.addAll(allIds);
              }
            }),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              NeoSmallButton(
                label: 'CANCEL',
                onTap: busy ? null : _exitSelect,
              ),
              NeoSmallButton(
                label: 'EDIT',
                icon: Icons.edit_rounded,
                primary: true,
                loading: _bulkEditing,
                onTap: (busy || none) ? null : _bulkEditSelected,
              ),
              NeoSmallButton(
                label: 'DELETE',
                icon: Icons.delete_outline_rounded,
                primary: true,
                color: Neo.pink,
                loading: _bulkDeleting,
                onTap: (busy || none) ? null : confirmDeleteSelected,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ===========================================================
  // SHARED FORM DIALOG (edit video / create + edit playlist)
  // ===========================================================
  Future<void> _formDialog({
    required String title,
    required IconData icon,
    required String saveLabel,
    required List<Widget> fields,
    required Future<void> Function() onSave,
    required String successMessage,
    required String errorPrefix,
    String? Function()? validate,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        bool saving = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return NeoDialog(
              title: title,
              sub: 'MANAGE // FORM',
              icon: icon,
              content: Column(children: fields),
              actions: [
                NeoSmallButton(
                  label: 'CANCEL',
                  onTap: saving ? null : () => Navigator.pop(dialogContext),
                ),
                NeoSmallButton(
                  label: saveLabel,
                  primary: true,
                  loading: saving,
                  onTap: saving
                      ? null
                      : () async {
                          final err = validate?.call();
                          if (err != null) {
                            showError(err);
                            return;
                          }

                          setDialogState(() {
                            saving = true;
                          });

                          try {
                            await onSave();

                            if (!mounted || !dialogContext.mounted) {
                              return;
                            }

                            Navigator.pop(dialogContext);
                            neoSnack(this.context, successMessage);
                          } catch (e) {
                            if (dialogContext.mounted) {
                              setDialogState(() {
                                saving = false;
                              });
                            }
                            showError('$errorPrefix: $e');
                          }
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> showEditVideoDialog(
    String videoId,
    Map<String, dynamic> data,
  ) async {
    final titleController = TextEditingController(
      text: data['title']?.toString() ?? '',
    );
    final categoryController = TextEditingController(
      text: data['category']?.toString() ?? '',
    );
    final videoUrlController = TextEditingController(
      text: data['videoUrl']?.toString() ?? '',
    );
    final thumbnailController = TextEditingController(
      text: data['thumbnailUrl']?.toString() ?? '',
    );
    final seasonController = TextEditingController(
      text: data['season']?.toString() ?? '',
    );
    final episodeController = TextEditingController(
      text: data['episodes']?.toString() ?? '',
    );

    await _formDialog(
      title: 'Edit Video',
      icon: Icons.edit_rounded,
      saveLabel: 'SAVE',
      successMessage: 'Video updated successfully',
      errorPrefix: 'Failed to update video',
      validate: () =>
          titleController.text.trim().isEmpty ? 'Title is required' : null,
      fields: [
        buildTextField(controller: titleController, label: 'Title'),
        buildTextField(controller: categoryController, label: 'Category'),
        buildTextField(controller: videoUrlController, label: 'Video URL'),
        buildTextField(
          controller: thumbnailController,
          label: 'Thumbnail URL',
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: buildTextField(
                controller: seasonController,
                label: 'Season',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: buildTextField(
                controller: episodeController,
                label: 'Episode',
              ),
            ),
          ],
        ),
      ],
      onSave: () async {
        await _firestore.collection('videos').doc(videoId).update({
          'title': titleController.text.trim(),
          'category': categoryController.text.trim(),
          'videoUrl': videoUrlController.text.trim(),
          'thumbnailUrl': thumbnailController.text.trim(),
          'season': seasonController.text.trim(),
          'episodes': episodeController.text.trim(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      },
    );
  }

  Future<void> showCreatePlaylistDialog() async {
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    final thumbnailController = TextEditingController();

    await _formDialog(
      title: 'Create Playlist',
      icon: Icons.playlist_add_rounded,
      saveLabel: 'CREATE',
      successMessage: 'Playlist created successfully',
      errorPrefix: 'Failed to create playlist',
      validate: () =>
          nameController.text.trim().isEmpty ? 'Playlist name is required' : null,
      fields: [
        buildTextField(controller: nameController, label: 'Playlist Name'),
        buildTextField(
          controller: descriptionController,
          label: 'Description',
          maxLines: 3,
        ),
        buildTextField(
          controller: thumbnailController,
          label: 'Thumbnail URL',
        ),
      ],
      onSave: () async {
        await _firestore.collection('playlists').add({
          'name': nameController.text.trim(),
          'description': descriptionController.text.trim(),
          'thumbnailUrl': thumbnailController.text.trim(),
          'videoIds': [],
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      },
    );
  }

  Future<void> showEditPlaylistDialog(
    String playlistId,
    Map<String, dynamic> data,
  ) async {
    final nameController = TextEditingController(
      text: data['name']?.toString() ?? '',
    );
    final descriptionController = TextEditingController(
      text: data['description']?.toString() ?? '',
    );
    final thumbnailController = TextEditingController(
      text: data['thumbnailUrl']?.toString() ?? '',
    );

    await _formDialog(
      title: 'Edit Playlist',
      icon: Icons.edit_rounded,
      saveLabel: 'SAVE',
      successMessage: 'Playlist updated successfully',
      errorPrefix: 'Failed to update playlist',
      validate: () =>
          nameController.text.trim().isEmpty ? 'Playlist name is required' : null,
      fields: [
        buildTextField(controller: nameController, label: 'Playlist Name'),
        buildTextField(
          controller: descriptionController,
          label: 'Description',
          maxLines: 3,
        ),
        buildTextField(
          controller: thumbnailController,
          label: 'Thumbnail URL',
        ),
      ],
      onSave: () async {
        await _firestore.collection('playlists').doc(playlistId).update({
          'name': nameController.text.trim(),
          'description': descriptionController.text.trim(),
          'thumbnailUrl': thumbnailController.text.trim(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      },
    );
  }

  Future<void> deletePlaylist(String playlistId, String playlistName) async {
    try {
      await _firestore.collection('playlists').doc(playlistId).delete();

      if (!mounted) return;

      neoSnack(context, '"$playlistName" deleted successfully');
    } catch (e) {
      showError('Failed to delete playlist: $e');
    }
  }

  Future<void> confirmDeletePlaylist(
    String playlistId,
    String playlistName,
  ) async {
    final ok = await neoConfirm(
      context,
      title: 'Delete Playlist?',
      message: 'Delete "$playlistName"?\n\n'
          'Videos inside the playlist will NOT be deleted. '
          'Only the playlist will be deleted.',
      confirmLabel: 'DELETE',
      danger: true,
    );

    if (ok) {
      await deletePlaylist(playlistId, playlistName);
    }
  }

  // ===========================================================
  // PICKER UI HELPERS (shared by Add Videos + Playlist Videos)
  // ===========================================================
  Widget _check(bool on) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: on
            ? const LinearGradient(colors: [Neo.cyan, Neo.violet])
            : null,
        border: Border.all(color: on ? Neo.cyan : Neo.line, width: 1.4),
      ),
      child: on
          ? const Icon(Icons.check_rounded, size: 17, color: Neo.bg)
          : null,
    );
  }

  Widget _selectAllRow({
    required bool all,
    required bool disabled,
    required int count,
    required VoidCallback onToggle,
  }) {
    return Row(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: disabled ? null : onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                _check(all),
                const SizedBox(width: 10),
                const Text(
                  'Select All',
                  style: TextStyle(
                    color: Neo.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        if (count > 0) NeoTag('$count SELECTED', color: Neo.cyan),
      ],
    );
  }

  Widget _pickTile({
    required String title,
    required String season,
    required String episode,
    required String thumbnail,
    required bool selected,
    required bool disabled,
    required VoidCallback onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? Neo.cyan.withValues(alpha: 0.10)
            : secondaryCardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? Neo.cyan.withValues(alpha: 0.6) : Neo.line,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: disabled ? null : onToggle,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                const SizedBox(width: 4),
                _check(selected),
                const SizedBox(width: 10),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: thumbnail.isNotEmpty
                        ? NeoImage(_getDriveThumbnailUrl(thumbnail))
                        : _imagePlaceholder(width: 56, height: 56),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Neo.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _seasonEpisode(season, episode),
                        style: const TextStyle(
                          color: Neo.muted,
                          fontFamily: Neo.mono,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _seasonEpisode(String season, String episode) {
    final parts = <String>[
      if (season.trim().isNotEmpty) 'S$season',
      if (episode.trim().isNotEmpty) 'EP $episode',
    ];
    return parts.isEmpty ? 'No season / episode' : parts.join(' • ');
  }

  // ===========================================================
  // ADD VIDEOS TO PLAYLIST
  // ===========================================================
  Future<void> showAddVideoDialog(
    String playlistId,
    String playlistName,
  ) async {
    try {
      final videosSnapshot = await _firestore.collection('videos').get();
      final assignedVideoIds = await getAssignedVideoIds();

      final availableVideos = videosSnapshot.docs.where((doc) {
        return !assignedVideoIds.contains(doc.id) && !_isMovieData(doc.data());
      }).toList();

      availableVideos.sort((a, b) {
        final dataA = a.data();
        final dataB = b.data();

        final seasonA = _getNumber(dataA['season']);
        final seasonB = _getNumber(dataB['season']);

        if (seasonA != seasonB) {
          return seasonA.compareTo(seasonB);
        }

        final episodeA = _getEpisodeNumber(dataA['episodes']);
        final episodeB = _getEpisodeNumber(dataB['episodes']);

        if (episodeA != episodeB) {
          return episodeA.compareTo(episodeB);
        }

        final titleA = (dataA['title'] ?? '').toString().toLowerCase();
        final titleB = (dataB['title'] ?? '').toString().toLowerCase();

        return titleA.compareTo(titleB);
      });

      if (!mounted) return;

      final Set<String> selectedVideoIds = {};
      final TextEditingController searchController = TextEditingController();
      String searchText = '';

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          bool saving = false;

          return StatefulBuilder(
            builder: (context, setDialogState) {
              final filteredVideos = availableVideos
                  .where((doc) => _matchesVideoSearch(doc.data(), searchText))
                  .toList();

              final allVisibleSelected = filteredVideos.isNotEmpty &&
                  filteredVideos.every((doc) {
                    return selectedVideoIds.contains(doc.id);
                  });

              final listHeight =
                  (MediaQuery.of(context).size.height * 0.42).clamp(180.0, 420.0);

              return NeoDialog(
                title: 'Add Videos',
                sub: playlistName.toUpperCase(),
                icon: Icons.playlist_add_rounded,
                content: Column(
                  children: [
                    NeoInput(
                      controller: searchController,
                      label: '',
                      hint: 'Search title, S2, EP5, S2E5...',
                      icon: Icons.search_rounded,
                      onChanged: (value) {
                        setDialogState(() {
                          searchText = value;
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    _selectAllRow(
                      all: allVisibleSelected,
                      disabled: saving,
                      count: selectedVideoIds.length,
                      onToggle: () {
                        setDialogState(() {
                          if (allVisibleSelected) {
                            for (final doc in filteredVideos) {
                              selectedVideoIds.remove(doc.id);
                            }
                          } else {
                            selectedVideoIds.addAll(
                              filteredVideos.map((doc) => doc.id),
                            );
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: listHeight,
                      child: filteredVideos.isEmpty
                          ? EmptyState(
                              icon: Icons.video_library_outlined,
                              text: availableVideos.isEmpty
                                  ? 'No unassigned videos available'
                                  : 'No videos found',
                            )
                          : ListView.builder(
                              itemCount: filteredVideos.length,
                              itemBuilder: (context, index) {
                                final doc = filteredVideos[index];
                                final data = doc.data();
                                final videoId = doc.id;

                                return _pickTile(
                                  title: data['title']?.toString() ?? 'Untitled',
                                  season: data['season']?.toString() ?? '',
                                  episode: data['episodes']?.toString() ?? '',
                                  thumbnail:
                                      data['thumbnailUrl']?.toString() ?? '',
                                  selected: selectedVideoIds.contains(videoId),
                                  disabled: saving,
                                  onToggle: () {
                                    setDialogState(() {
                                      if (selectedVideoIds.contains(videoId)) {
                                        selectedVideoIds.remove(videoId);
                                      } else {
                                        selectedVideoIds.add(videoId);
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
                actions: [
                  NeoSmallButton(
                    label: 'CANCEL',
                    onTap: saving ? null : () => Navigator.pop(dialogContext),
                  ),
                  NeoSmallButton(
                    label: saving
                        ? 'ADDING...'
                        : selectedVideoIds.isEmpty
                            ? 'ADD SELECTED'
                            : 'ADD (${selectedVideoIds.length})',
                    icon: Icons.playlist_add_rounded,
                    primary: true,
                    loading: saving,
                    onTap: selectedVideoIds.isEmpty || saving
                        ? null
                        : () async {
                            setDialogState(() {
                              saving = true;
                            });

                            try {
                              final selected = selectedVideoIds.toList();

                              final addedCount =
                                  await addMultipleVideosToPlaylist(
                                playlistId,
                                selected,
                              );

                              if (!context.mounted || !dialogContext.mounted) {
                                return;
                              }

                              Navigator.pop(dialogContext);

                              neoSnack(
                                this.context,
                                addedCount == 0
                                    ? 'Selected videos are already assigned'
                                    : '$addedCount video${addedCount == 1 ? '' : 's'} added to playlist',
                              );
                            } catch (e) {
                              if (dialogContext.mounted) {
                                setDialogState(() {
                                  saving = false;
                                });
                              }
                              showError('Failed to add videos: $e');
                            }
                          },
                  ),
                ],
              );
            },
          );
        },
      );
    } catch (e) {
      showError('Unable to load videos: $e');
    }
  }

  // ===========================================================
  // PLAYLIST VIDEOS (view + bulk remove)
  // ===========================================================
  Future<void> openPlaylistVideos(
    String playlistId,
    String playlistName,
    List<dynamic> videoIds,
  ) async {
    try {
      final ids = videoIds
          .map((id) => id.toString())
          .where((id) => id.isNotEmpty)
          .toList();

      if (ids.isEmpty) {
        if (!mounted) return;

        showDialog<void>(
          context: context,
          builder: (dialogContext) {
            return NeoDialog(
              title: 'Playlist Videos',
              sub: playlistName.toUpperCase(),
              icon: Icons.video_library_outlined,
              content: const Text(
                'No videos added to this playlist.',
                style: TextStyle(color: Neo.muted, fontSize: 14, height: 1.45),
              ),
              actions: [
                NeoSmallButton(
                  label: 'CLOSE',
                  primary: true,
                  onTap: () => Navigator.pop(dialogContext),
                ),
              ],
            );
          },
        );

        return;
      }

      final snapshot = await _firestore.collection('videos').get();

      final List<Map<String, dynamic>> videos = snapshot.docs
          .where((doc) {
            return ids.contains(doc.id);
          })
          .map((doc) {
            final data = doc.data();

            return {
              'id': doc.id,
              'title': data['title'] ?? 'Untitled',
              'thumbnailUrl': data['thumbnailUrl'] ?? '',
              'episodes': data['episodes'] ?? '',
              'season': data['season'] ?? '',
              'videoUrl': data['videoUrl'] ?? '',
            };
          })
          .toList();

      _sortVideosBySeasonAndEpisode(videos);

      if (!mounted) return;

      final Set<String> selectedVideoIds = {};

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          bool removing = false;

          return StatefulBuilder(
            builder: (context, setDialogState) {
              final allSelected =
                  videos.isNotEmpty && selectedVideoIds.length == videos.length;

              final listHeight =
                  (MediaQuery.of(context).size.height * 0.46).clamp(180.0, 460.0);

              return NeoDialog(
                title: playlistName,
                sub: '${videos.length} VIDEOS',
                icon: Icons.playlist_play_rounded,
                accent: Neo.violet,
                content: Column(
                  children: [
                    _selectAllRow(
                      all: allSelected,
                      disabled: removing,
                      count: selectedVideoIds.length,
                      onToggle: () {
                        setDialogState(() {
                          if (allSelected) {
                            selectedVideoIds.clear();
                          } else {
                            selectedVideoIds.addAll(
                              videos.map((video) => video['id'].toString()),
                            );
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: listHeight,
                      child: videos.isEmpty
                          ? const EmptyState(
                              icon: Icons.video_library_outlined,
                              text: 'Videos not found',
                            )
                          : ListView.builder(
                              itemCount: videos.length,
                              itemBuilder: (context, index) {
                                final video = videos[index];
                                final videoId = video['id'].toString();

                                return _pickTile(
                                  title: video['title'].toString(),
                                  season: video['season'].toString(),
                                  episode: video['episodes'].toString(),
                                  thumbnail: video['thumbnailUrl'].toString(),
                                  selected: selectedVideoIds.contains(videoId),
                                  disabled: removing,
                                  onToggle: () {
                                    setDialogState(() {
                                      if (selectedVideoIds.contains(videoId)) {
                                        selectedVideoIds.remove(videoId);
                                      } else {
                                        selectedVideoIds.add(videoId);
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
                actions: [
                  NeoSmallButton(
                    label: 'CLOSE',
                    onTap: removing ? null : () => Navigator.pop(dialogContext),
                  ),
                  NeoSmallButton(
                    label: removing
                        ? 'REMOVING...'
                        : selectedVideoIds.isEmpty
                            ? 'REMOVE SELECTED'
                            : 'REMOVE (${selectedVideoIds.length})',
                    icon: Icons.delete_outline_rounded,
                    primary: true,
                    color: Neo.pink,
                    loading: removing,
                    onTap: selectedVideoIds.isEmpty || removing
                        ? null
                        : () async {
                            final count = selectedVideoIds.length;

                            final confirm = await neoConfirm(
                              dialogContext,
                              title: 'Remove Videos?',
                              message: 'Remove $count selected '
                                  'video${count == 1 ? '' : 's'} '
                                  'from "$playlistName"?',
                              confirmLabel: 'REMOVE',
                              danger: true,
                            );

                            if (!confirm) {
                              return;
                            }

                            setDialogState(() {
                              removing = true;
                            });

                            try {
                              final idsToRemove = selectedVideoIds.toList();

                              await removeMultipleVideosFromPlaylist(
                                playlistId,
                                idsToRemove,
                              );

                              if (!context.mounted) {
                                return;
                              }

                              videos.removeWhere((video) {
                                return idsToRemove.contains(
                                  video['id'].toString(),
                                );
                              });

                              selectedVideoIds.clear();
                              _sortVideosBySeasonAndEpisode(videos);

                              setDialogState(() {
                                removing = false;
                              });

                              neoSnack(
                                context,
                                '$count video${count == 1 ? '' : 's'} removed from playlist',
                              );
                            } catch (e) {
                              if (dialogContext.mounted) {
                                setDialogState(() {
                                  removing = false;
                                });
                              }
                              showError('Failed to remove videos: $e');
                            }
                          },
                  ),
                ],
              );
            },
          );
        },
      );
    } catch (e) {
      showError('Unable to load playlist videos: $e');
    }
  }

  // ===========================================================
  // LIST SCREENS
  // ===========================================================
  Widget _searchBar({
    required TextEditingController controller,
    required String hint,
    required String text,
    required ValueChanged<String> onChanged,
    required VoidCallback onClear,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: NeoInput(
        controller: controller,
        label: '',
        hint: hint,
        icon: Icons.search_rounded,
        onChanged: onChanged,
        suffix: text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close_rounded, color: Neo.muted, size: 20),
                onPressed: onClear,
              )
            : null,
      ),
    );
  }

  Widget buildVideoSearchBar() {
    return _searchBar(
      controller: _videoSearchController,
      hint: 'Search title, S2, EP5, S2E5...',
      text: _videoSearchText,
      onChanged: (value) {
        setState(() {
          _videoSearchText = value.toLowerCase().trim();
        });
      },
      onClear: () {
        _videoSearchController.clear();
        setState(() {
          _videoSearchText = '';
        });
      },
    );
  }

  Widget buildPlaylistSearchBar() {
    return _searchBar(
      controller: _playlistSearchController,
      hint: 'Search playlists...',
      text: _playlistSearchText,
      onChanged: (value) {
        setState(() {
          _playlistSearchText = value.toLowerCase().trim();
        });
      },
      onClear: () {
        _playlistSearchController.clear();
        setState(() {
          _playlistSearchText = '';
        });
      },
    );
  }

  Widget _skeletonList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, __) => ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: const SizedBox(height: 96, child: Shimmer()),
      ),
    );
  }

  Widget buildVideos() {
    return Column(
      children: [
        buildVideoSearchBar(),
        if (!_selecting)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: NeoSmallButton(
                label: 'SELECT',
                icon: Icons.checklist_rounded,
                onTap: () => setState(() => _selMode = true),
              ),
            ),
          ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _videosStream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ErrorState(text: 'Error: ${snapshot.error}');
              }

              // Skeleton only for the very first load, never on a rebuild.
              if (!snapshot.hasData &&
                  snapshot.connectionState == ConnectionState.waiting) {
                return _skeletonList();
              }

              final docs = snapshot.data?.docs ?? [];

              _docCache = {for (final d in docs) d.id: d.data()};

              final filteredDocs = docs
                  .where((doc) => _matchesVideoSearch(doc.data(), _videoSearchText))
                  .toList();

              if (filteredDocs.isEmpty) {
                return EmptyState(
                  icon: Icons.video_library_outlined,
                  text: _videoSearchText.isEmpty
                      ? 'No videos found'
                      : 'No videos found for "$_videoSearchText"',
                );
              }

              final items = _buildGroupedItems(filteredDocs);

              return Column(
                children: [
                  if (_selecting) _selectionBar(filteredDocs),
                  Expanded(
                    child: NeoRefresh(onRefresh: () => refreshFromServer(const ['videos']), child: ListView.builder(
physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];

                  if (item is _GroupHeader) {
                    return _groupHeader(item);
                  }

                  final doc =
                      item as QueryDocumentSnapshot<Map<String, dynamic>>;

                  return KeyedSubtree(
                    key: ValueKey(doc.id),
                    child: FadeIn(
                      index: index,
                      child: buildVideoCard(doc),
                    ),
                  );
                },
              )),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget buildPlaylists() {
    return Column(
      children: [
        buildPlaylistSearchBar(),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _allVideosStream,
            builder: (context, videoSnapshot) {
              final existingVideoIds =
                  videoSnapshot.data?.docs.map((doc) => doc.id).toSet() ??
                      <String>{};

              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _playlistsStream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return ErrorState(text: 'Error: ${snapshot.error}');
                  }

                  if (!snapshot.hasData &&
                      snapshot.connectionState == ConnectionState.waiting) {
                    return _skeletonList();
                  }

                  final docs = snapshot.data?.docs ?? [];

                  final filteredDocs = docs.where((doc) {
                    if (_playlistSearchText.isEmpty) {
                      return true;
                    }

                    final data = doc.data();

                    final name = (data['name'] ?? '').toString().toLowerCase();
                    final description =
                        (data['description'] ?? '').toString().toLowerCase();

                    return name.contains(_playlistSearchText) ||
                        description.contains(_playlistSearchText);
                  }).toList();

                  if (filteredDocs.isEmpty) {
                    return EmptyState(
                      icon: Icons.playlist_play_rounded,
                      text: _playlistSearchText.isEmpty
                          ? 'No playlists found'
                          : 'No playlists found for "$_playlistSearchText"',
                    );
                  }

                  return NeoRefresh(onRefresh: () => refreshFromServer(const ['playlists', 'videos']), child: ListView.builder(
physics: const AlwaysScrollableScrollPhysics(),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                    itemCount: filteredDocs.length,
                    itemBuilder: (context, index) {
                      final doc = filteredDocs[index];
                      final data = doc.data();

                      final videoIds = data['videoIds'] is List
                          ? List<dynamic>.from(data['videoIds'])
                          : <dynamic>[];

                      final accurateCount = videoIds
                          .map((id) => id.toString())
                          .where((id) => existingVideoIds.contains(id))
                          .toSet()
                          .length;

                      return FadeIn(
                        index: index,
                        child: buildPlaylistCard(doc, accurateCount),
                      );
                    },
                  ));
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _miniAction({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color.withValues(alpha: 0.10),
        shape: CircleBorder(side: BorderSide(color: color.withValues(alpha: 0.35))),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, color: color, size: 19),
          ),
        ),
      ),
    );
  }

  BoxDecoration _cardDeco(Color glow) => BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Neo.line),
        boxShadow: [
          BoxShadow(
            color: glow.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      );

  Widget buildVideoCard(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();

    final title = data['title']?.toString() ?? 'Untitled';
    final category = data['category']?.toString() ?? '';
    final season = data['season']?.toString() ?? '';
    final episode = data['episodes']?.toString() ?? '';
    final thumbnail = data['thumbnailUrl']?.toString() ?? '';
    final selected = _selectedIds.contains(doc.id);
    final isMovie = category.trim().toLowerCase() == 'movies';
    final unreleased = isMovie && data['released'] == false;
    final released = isMovie && data['released'] != false;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: _bulkDeleting ? null : () => _toggleSelected(doc.id),
      onTap: _bulkDeleting
          ? null
          : _selecting
              ? () => _toggleSelected(doc.id)
              : () => _openVideo(doc.id),
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: selected
          ? _cardDeco(Neo.cyan).copyWith(
              border: Border.all(color: Neo.cyan, width: 1.6))
          : _cardDeco(Neo.cyan),
      child: Row(
        children: [
          if (_selecting) ...[
            _check(selected),
            const SizedBox(width: 10),
          ],
          SizedBox(
            width: 104,
            height: 76,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: thumbnail.isNotEmpty
                  ? NeoImage(_getDriveThumbnailUrl(thumbnail))
                  : _imagePlaceholder(width: 104, height: 76),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Neo.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (category.isNotEmpty) NeoTag(category, color: Neo.violet),
                    if (unreleased) NeoTag('UNRELEASED', color: Neo.pink),
                    if (season.isNotEmpty) NeoTag('S$season', color: Neo.amber),
                    if (episode.isNotEmpty) NeoTag('EP $episode', color: Neo.cyan),
                  ],
                ),
              ],
            ),
          ),
          if (!_selecting) ...[
            const SizedBox(width: 8),
            Column(
              children: [
                if (unreleased) ...[
                  _miniAction(
                    icon: Icons.rocket_launch_outlined,
                    tooltip: 'Release',
                    color: Neo.amber,
                    onTap: () => _releaseMovie(doc.id, title),
                  ),
                  const SizedBox(height: 8),
                ],
                if (released) ...[
                  _miniAction(
                    icon: Icons.visibility_off_outlined,
                    tooltip: 'Unrelease',
                    color: Neo.violet,
                    onTap: () => _unreleaseMovie(doc.id, title),
                  ),
                  const SizedBox(height: 8),
                ],
                _miniAction(
                  icon: Icons.edit_outlined,
                  tooltip: 'Edit',
                  color: Neo.cyan,
                  onTap: () {
                    showEditVideoDialog(doc.id, data);
                  },
                ),
                const SizedBox(height: 8),
                _miniAction(
                  icon: Icons.delete_outline_rounded,
                  tooltip: 'Delete',
                  color: Neo.pink,
                  onTap: () {
                    confirmDeleteVideo(doc.id, title);
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    ));
  }

  Widget buildPlaylistCard(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    int accurateVideoCount,
  ) {
    final data = doc.data();

    final name = data['name']?.toString() ?? 'Untitled Playlist';
    final description = data['description']?.toString() ?? '';
    final thumbnail = data['thumbnailUrl']?.toString() ?? '';

    final videoIds = data['videoIds'] is List
        ? List<dynamic>.from(data['videoIds'])
        : <dynamic>[];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: _cardDeco(Neo.violet),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () {
            openPlaylistVideos(doc.id, name, videoIds);
          },
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 104,
                      height: 76,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: thumbnail.isNotEmpty
                            ? NeoImage(
                                _getDriveThumbnailUrl(thumbnail),
                                fallbackIcon: Icons.playlist_play_rounded,
                              )
                            : _imagePlaceholder(width: 104, height: 76),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Neo.text,
                              fontWeight: FontWeight.w800,
                              fontSize: 15.5,
                              height: 1.2,
                            ),
                          ),
                          if (description.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Neo.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          NeoTag(
                            '$accurateVideoCount '
                            'VIDEO${accurateVideoCount == 1 ? '' : 'S'}',
                            color: Neo.violet,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _miniAction(
                      icon: Icons.playlist_add_rounded,
                      tooltip: 'Add Videos',
                      color: Neo.cyan,
                      onTap: () {
                        showAddVideoDialog(doc.id, name);
                      },
                    ),
                    const SizedBox(width: 8),
                    _miniAction(
                      icon: Icons.edit_outlined,
                      tooltip: 'Edit Playlist',
                      color: Neo.amber,
                      onTap: () {
                        showEditPlaylistDialog(doc.id, data);
                      },
                    ),
                    const SizedBox(width: 8),
                    _miniAction(
                      icon: Icons.delete_outline_rounded,
                      tooltip: 'Delete Playlist',
                      color: Neo.pink,
                      onTap: () {
                        confirmDeletePlaylist(doc.id, name);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildTextField({
    required TextEditingController controller,
    required String label,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: NeoInput(
        controller: controller,
        label: label,
        hint: label,
        maxLines: maxLines,
      ),
    );
  }

  void showError(String message) {
    if (!mounted) return;

    neoSnack(context, message, error: true);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AdminService.notifier,
        builder: (c, isAdmin, _) => isAdmin
            ? _page(c)
            : const NeoScaffold(
                overline: 'Access // Restricted',
                title: 'Manage Videos',
                body: EmptyState(
                  icon: Icons.lock_outline_rounded,
                  text: 'Admin access only',
                  sub: 'Sign in with the admin account to manage videos.',
                ),
              ),
      );

  Widget _page(BuildContext context) {
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_bulkDeleting) _exitSelect();
      },
      child: _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    return NeoScaffold(
      overline: 'Admin // Library',
      title: 'Manage Videos',
      maxWidth: 960,
      fab: AnimatedBuilder(
        animation: _tabController,
        builder: (context, child) {
          if (_tabController.index != 1) {
            return const SizedBox.shrink();
          }

          return FloatingActionButton.extended(
            backgroundColor: Neo.cyan,
            foregroundColor: Neo.bg,
            onPressed: showCreatePlaylistDialog,
            icon: const Icon(Icons.playlist_add_rounded),
            label: const Text(
              'CREATE PLAYLIST',
              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.8),
            ),
          );
        },
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Neo.line),
            ),
            child: TabBar(
              controller: _tabController,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(colors: [Neo.cyan, Neo.violet]),
              ),
              labelColor: Neo.bg,
              unselectedLabelColor: Neo.muted,
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                letterSpacing: 0.6,
              ),
              splashBorderRadius: BorderRadius.circular(14),
              tabs: const [
                Tab(
                  height: 42,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.video_library_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('Videos'),
                    ],
                  ),
                ),
                Tab(
                  height: 42,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.playlist_play_outlined, size: 20),
                      SizedBox(width: 8),
                      Text('Playlists'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [buildVideos(), buildPlaylists()],
            ),
          ),
        ],
      ),
    );
  }
}


/// Bulk edit sheet for the Videos tab. Blank field = keep each video's own value.
/// Pops a map of strings: find, replace, title, category, season, episode,
/// video_url, thumbnail_url, description.
class _BulkVideoEditForm extends StatefulWidget {
  const _BulkVideoEditForm();

  @override
  State<_BulkVideoEditForm> createState() => _BulkVideoEditFormState();
}

class _BulkVideoEditFormState extends State<_BulkVideoEditForm> {
  final Map<String, TextEditingController> _c = {
    for (final k in const [
      'find', 'replace', 'title', 'category', 'season', 'episode',
      'video_url', 'thumbnail_url', 'description'
    ])
      k: TextEditingController(),
  };
  String? _err;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _http(String u) => u.startsWith('http://') || u.startsWith('https://');

  void _save() {
    String v(String k) => _c[k]!.text.trim();
    if (_c.values.every((c) => c.text.trim().isEmpty)) {
      return setState(() => _err = 'Fill at least one field.');
    }
    for (final k in const ['season', 'episode']) {
      if (v(k).isNotEmpty) {
        final n = int.tryParse(v(k));
        if (n == null || n < 0) {
          return setState(() => _err = 'Season / episode must be numbers.');
        }
      }
    }
    for (final k in const ['video_url', 'thumbnail_url']) {
      if (v(k).isNotEmpty && !_http(v(k))) {
        return setState(() => _err = 'URLs must start with http(s)://');
      }
    }
    Navigator.pop(context, <String, String>{
      'find': _c['find']!.text, // keep inner spaces exactly as typed
      'replace': _c['replace']!.text,
      for (final k in const [
        'title', 'category', 'season', 'episode',
        'video_url', 'thumbnail_url', 'description'
      ])
        k: v(k),
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Blank = keep each video as it is',
                  style: TextStyle(color: Neo.muted, fontSize: 12)),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: NeoInput(
                    controller: _c['find']!,
                    label: 'Title: find',
                    icon: Icons.search_rounded),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: NeoInput(
                    controller: _c['replace']!, label: 'Replace with'),
              ),
            ]),
            const SizedBox(height: 10),
            NeoInput(
                controller: _c['title']!,
                label: 'Title (same for all)',
                icon: Icons.title_rounded),
            const SizedBox(height: 10),
            NeoInput(
                controller: _c['category']!,
                label: 'Category',
                icon: Icons.category_rounded),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: NeoInput(
                    controller: _c['season']!,
                    label: 'Season',
                    keyboardType: TextInputType.number),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: NeoInput(
                    controller: _c['episode']!,
                    label: 'Episode',
                    keyboardType: TextInputType.number),
              ),
            ]),
            const SizedBox(height: 10),
            NeoInput(
                controller: _c['video_url']!,
                label: 'Video URL',
                icon: Icons.link_rounded,
                keyboardType: TextInputType.url),
            const SizedBox(height: 10),
            NeoInput(
                controller: _c['thumbnail_url']!,
                label: 'Thumbnail URL',
                icon: Icons.image_rounded,
                keyboardType: TextInputType.url),
            const SizedBox(height: 10),
            NeoInput(
                controller: _c['description']!,
                label: 'Description',
                icon: Icons.notes_rounded,
                maxLines: 3),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!, style: const TextStyle(color: Neo.pink, fontSize: 12)),
            ],
            const SizedBox(height: 14),
            NeoButton(
                label: 'APPLY TO ALL',
                icon: Icons.done_all_rounded,
                onTap: _save),
          ]),
        ),
      );
}

/// Section header row (anime name or season) used by the grouped video list.
class _GroupHeader {
  final String title;
  final int count;
  final bool isAnime;

  const _GroupHeader(this.title, {this.count = 0, this.isAnime = false});
}