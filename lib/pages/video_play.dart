import 'dart:async';
import 'dart:math' as rnd;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/api_client.dart';
import '../services/last_watched_service.dart';
import '../ui/download_button.dart';
import '../services/platform_flags.dart';
import '../services/screen_awake_service.dart';
import '../services/stream_perf.dart';
import '../ui/desktop.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/neo.dart';
import '../ui/refresh.dart';

class VideoPlayPage extends StatefulWidget {
  final String videoId;
  final String playlistId;

  /// Resume point (used by the "Continue Watching" popup).
  final Duration? startAt;

  /// Open straight in fullscreen (landscape): used when next/previous is pressed in fullscreen.
  final bool startFullscreen;

  const VideoPlayPage({
    super.key,
    required this.videoId,
    required this.playlistId,
    this.startAt,
    this.startFullscreen = false,
  });

  @override
  State<VideoPlayPage> createState() => _VideoPlayPageState();
}

class _VideoPlayPageState extends State<VideoPlayPage>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;

  // Last watched tracking
  String _thumbnail = '';
  Timer? _saveTimer;
  bool _wasPlaying = false;

  // ============================================================
  // STATE
  // ============================================================

  bool _loading = true;
  bool _hasError = false;
  bool _fg = true; // app in foreground (screen-awake only matters then)
  bool _showControls = true;
  Timer? _ctlTimer;

  void _pokeControls() {
    if (!_showControls && mounted) setState(() => _showControls = true);
    _ctlTimer?.cancel();
    _ctlTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) setState(() => _showControls = false);
    });
  }


  String _errorMessage = '';
  String _title = '';
  String _season = '';
  String _episode = '';
  String _videoUrl = '';

  double _playbackSpeed = 1.0;

  // Multi-language (Tamil / English / Japanese only)
  static const List<String> _langOrder = ['tamil', 'english', 'japanese'];
  static const Map<String, String> _langLabel = {
    'tamil': 'TAMIL',
    'english': 'ENGLISH',
    'japanese': 'JAPANESE',
  };
  static const Map<String, String> _langShort = {
    'tamil': 'TA',
    'english': 'EN',
    'japanese': 'JA',
  };
  Map<String, String> _langUrls = {}; // language -> video url
  Map<String, String> _audioTracks = {}; // language -> audio track id (same file)
  Set<String> get _availLangs => {..._langUrls.keys, ..._audioTracks.keys};
  String _trackDebug = 'Audio tracks not loaded yet.';
  String _activeLang = '';
  bool _switchingLang = false;

  // More Videos
  List<DocumentSnapshot<Map<String, dynamic>>> _moreVideos = [];
  bool _moreVideosLoaded = false;

  // Pull-to-refresh: a pull that STARTS on the More Videos section refreshes only that section;
  // a pull from the top (info area) refreshes the whole page. Playback is never touched.
  final GlobalKey _moreKey = GlobalKey();
  bool _feedGesture = false;
  double _feedPull = 0;
  final ValueNotifier<double> _pullUi = ValueNotifier(0);
  bool _refreshing = false; // full-page refresh running
  bool _refreshingMore = false; // More Videos refresh running
  static const double _feedPullTrigger = 64;

  // Previous / Next (episode order inside the playlist)
  String? _prevId;
  String? _nextId;
  String _nextUrl = ''; // original URL of the next episode (for preloading)
  bool _preloadStarted = false;
  bool _autoNextDone = false; // auto-play-next fires only once per episode
  bool _inFullscreen = false; // fullscreen page handles its own auto-next
  bool _keepLandscape = false; // handing over to the next/prev page: don't force portrait

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
    ApiClient.wake(); // wake the backend now so Download etc. never hit a cold start
    _loadPage();
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _ctlTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    _pullUi.dispose();
    _saveTimer?.cancel();

    // Save the final position BEFORE the controller is disposed.
    _saveLastWatched();

    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    StreamPreload.clearSoon();
    ScreenAwakeService.release(this);

    if (!_keepLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }

    super.dispose();
  }

  // ============================================================
  // LOAD COMPLETE PAGE
  // ============================================================

  Future<void> _loadPage() async {
    if (!mounted) return;

    _saveTimer?.cancel();
    ScreenAwakeService.release(this);
    _controller?.removeListener(_videoListener);
    await _controller?.dispose();
    _controller = null;

    setState(() {
      _loading = true;
      _hasError = false;
      _errorMessage = '';
      _showControls = true;
      _title = '';
      _season = '';
      _episode = '';
      _videoUrl = '';
      _langUrls = {};
      _audioTracks = {};
      _activeLang = '';
      _switchingLang = false;
      _moreVideos = [];
      _moreVideosLoaded = false;
      _nextUrl = '';
      _preloadStarted = false;
      _autoNextDone = false;
    });

    try {
      // ----------------------------------------------------------
      // 1. LOAD VIDEO DOCUMENT
      // ----------------------------------------------------------

      // Cache first: the list pages already read this document, so no server round trip.
      // (If the stored link turns out to be stale, the server copy is fetched below.)
      DocumentSnapshot<Map<String, dynamic>>? cachedDoc;
      try {
        final c = await FirebaseFirestore.instance
            .collection('videos')
            .doc(widget.videoId)
            .get(const GetOptions(source: Source.cache));
        if (c.exists) cachedDoc = c;
      } catch (_) {}
      final usedCache = cachedDoc != null;

      final doc = cachedDoc ??
          await FirebaseFirestore.instance
              .collection('videos')
              .doc(widget.videoId)
              .get();

      if (!doc.exists) {
        throw Exception('Video not found in Firestore.');
      }

      final data = doc.data();

      if (data == null) {
        throw Exception('Video data is empty.');
      }

      // ----------------------------------------------------------
      // TITLE
      // ----------------------------------------------------------

      _title = _readString(data, [
        'title',
        'name',
        'videoTitle',
      ], fallback: 'Untitled Video');

      // ----------------------------------------------------------
      // SEASON
      // Current video only
      // ----------------------------------------------------------

      _season = _readString(data, ['season', 'seasonNumber']);

      // ----------------------------------------------------------
      // EPISODE
      // Supports multiple possible Firestore field names
      // ----------------------------------------------------------

      _episode = _readString(data, [
        'episodes',
        'episodeNumber',
        'episode',
        'episodeNo',
        'ep',
      ]);

      // ----------------------------------------------------------
      // VIDEO URL
      // ----------------------------------------------------------

      _videoUrl = _readString(data, ['videoUrl', 'url', 'videoURL']);

      if (_videoUrl.isEmpty) {
        throw Exception('Video URL is empty.');
      }

      // ----------------------------------------------------------
      // THUMBNAIL (stored with last watched)
      // ----------------------------------------------------------

      final rawThumb = _readString(data, [
        'thumbnail',
        'thumbnailUrl',
        'imageUrl',
        'posterUrl',
      ]);

      _thumbnail = _getThumbnailUrl(rawThumb.isNotEmpty ? rawThumb : _videoUrl);

      // Show title / episode right away; only the player area keeps loading.
      if (mounted) setState(() {});

      // ----------------------------------------------------------
      // 2. INITIALIZE ACTUAL VIDEO
      // ----------------------------------------------------------

      try {
        await _initializeVideo(_videoUrl);
      } catch (e) {
        if (!usedCache) rethrow;
        // cached document may be outdated: try the server copy once
        final fresh = await FirebaseFirestore.instance
            .collection('videos')
            .doc(widget.videoId)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 15));
        final freshUrl = _readString(fresh.data() ?? <String, dynamic>{}, ['videoUrl', 'url', 'videoURL']);
        if (freshUrl.isEmpty || freshUrl == _videoUrl) rethrow;
        _videoUrl = freshUrl;
        await _initializeVideo(_videoUrl);
      }

      if (!mounted) return;

      // ----------------------------------------------------------
      // VIDEO READY
      // ----------------------------------------------------------

      setState(() {
        _loading = false;
      });

      debugPrint('VIDEO INITIALIZED - LOADING STOPPED');

      // Came from fullscreen next/prev -> stay in fullscreen landscape.
      if (widget.startFullscreen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openFullscreen();
        });
      }

      // Save immediately (overwrites previous last watched),
      // then keep updating every 15 seconds.
      _saveLastWatched();
      _startSaveTimer();

      // ----------------------------------------------------------
      // 3. LOAD MORE VIDEOS IN BACKGROUND
      // ----------------------------------------------------------

      _loadMoreVideosInBackground();
      _loadLanguages(data);
      _loadAudioTracks();
    } catch (e) {
      debugPrint('VIDEO PAGE LOAD ERROR: $e');

      if (!mounted) return;

      setState(() {
        _loading = false;
        _hasError = true;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ============================================================
  // READ STRING
  // ============================================================

  String _readString(
    Map<String, dynamic> data,
    List<String> keys, {
    String fallback = '',
  }) {
    for (final key in keys) {
      final value = data[key];

      if (value != null) {
        final text = value.toString().trim();

        if (text.isNotEmpty) {
          return text;
        }
      }
    }

    return fallback;
  }

  // ============================================================
  // GOOGLE DRIVE FILE ID
  // ============================================================

  String? _extractDriveFileId(String url) {
    try {
      final uri = Uri.parse(url);

      final segments = uri.pathSegments;

      final dIndex = segments.indexOf('d');

      if (dIndex != -1 && dIndex + 1 < segments.length) {
        final id = segments[dIndex + 1].trim();

        if (id.isNotEmpty) {
          return id;
        }
      }

      final queryId = uri.queryParameters['id'];

      if (queryId != null && queryId.isNotEmpty) {
        return queryId;
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // VIDEO URL CANDIDATES
  // ============================================================

  List<String> _buildVideoCandidates(String originalUrl) => StreamCandidates.build(originalUrl);

  // ============================================================
  // INITIALIZE VIDEO
  // ============================================================

  Future<void> _initializeVideo(String originalUrl, {Duration? resumeAt}) async {
    var candidates = _buildVideoCandidates(originalUrl);

    if (candidates.isEmpty) {
      throw Exception('No valid video URL found.');
    }

    final sw = Stopwatch()..start();

    // The previous episode already prepared this one -> start right away.
    final pre = kStreamOptimizations ? StreamPreload.take(originalUrl) : null;
    if (pre != null) {
      try {
        await pre.setPlaybackSpeed(_playbackSpeed);
        final at = resumeAt ?? widget.startAt;
        if (at != null && at > Duration.zero && at < pre.value.duration) await pre.seekTo(at);
        if (!mounted) {
          await pre.dispose();
          return;
        }
        _controller = pre;
        _controller!.addListener(_videoListener);
        await _controller!.play();
        StreamPerf.record('player-ready', sw.elapsedMilliseconds, note: 'preloaded');
        return;
      } catch (_) {
        await pre.dispose(); // fall through to the normal start
      }
    }

    String? cachedUrl;
    if (kStreamOptimizations) {
      // (a) the URL that worked last time -> start immediately, no guessing
      cachedUrl = await StreamUrlCache.get(originalUrl);
      if (cachedUrl != null && candidates.contains(cachedUrl)) {
        candidates = [cachedUrl, ...candidates.where((c) => c != cachedUrl)];
      } else {
        cachedUrl = null;
        // (b) otherwise probe all variants in parallel and try the one that answers first
        candidates = await StreamProbe.order(candidates);
        StreamPerf.record('probe', sw.elapsedMilliseconds);
      }
    }

    // Drive often rejects/throttles a request once and accepts it a moment later,
    // so go through all URL variants up to 3 times before giving up.
    for (var round = 0; round < 3; round++) {
      if (!mounted) return;
      if (round > 0) await Future.delayed(Duration(milliseconds: 1200 * round));
      var queue = List<String>.from(candidates);
      while (queue.isNotEmpty) {
        final url = queue.removeAt(0);
        VideoPlayerController? testController;

        try {
          debugPrint('Trying video URL: $url');

          testController = VideoPlayerController.networkUrl(
            Uri.parse(url),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
          );

          // a link that hangs must not block the fallbacks
          await testController.initialize().timeout(Duration(seconds: queue.isEmpty ? 30 : 15));
          StreamPerf.record('player-ready', sw.elapsedMilliseconds,
              note: cachedUrl == url ? 'cached url' : (url == candidates.first ? 'first candidate' : 'fallback'));
          if (kStreamOptimizations) unawaited(StreamUrlCache.put(originalUrl, url));

          await testController.setPlaybackSpeed(_playbackSpeed);

          // Resume from saved position (Continue Watching)
          final startAt = resumeAt ?? widget.startAt;
          if (startAt != null &&
              startAt > Duration.zero &&
              startAt < testController.value.duration) {
            await testController.seekTo(startAt);
          }

          if (!mounted) {
            await testController.dispose();
            return;
          }

          _controller = testController;

          _controller!.addListener(_videoListener);

          await _controller!.play();

          debugPrint('VIDEO INITIALIZED SUCCESSFULLY');

          return;
        } catch (e) {
          debugPrint('FAILED VIDEO URL: $url');

          debugPrint('VIDEO ERROR: $e');

          await testController?.dispose();
          if (url == cachedUrl) {
            unawaited(StreamUrlCache.remove(originalUrl)); // stale -> forget it
            // pick the fastest of the remaining variants instead of trying them one by one
            if (kStreamOptimizations && queue.length > 1) queue = await StreamProbe.order(queue);
          }
        }
      }
    }

    throw Exception(
      'Google Drive video could not be loaded.\n\n'
      'Please check that the Drive file is accessible '
      'with the link.',
    );
  }


  // ============================================================
  // MULTI-LANGUAGE
  // ============================================================

  /// 'tamil' | 'english' | 'japanese' | null (anything else is ignored).
  String? _normLang(String raw, {bool allowShort = false}) {
    final t = raw.toLowerCase();
    if (RegExp(r'tamil|தமிழ்|\btam\b').hasMatch(t)) return 'tamil';
    if (RegExp(r'english|\beng\b').hasMatch(t)) return 'english';
    if (RegExp(r'japanese|\bjpn\b|\bjap\b').hasMatch(t)) return 'japanese';
    if (allowShort) {
      final c = t.trim();
      if (c == 'ta') return 'tamil';
      if (c == 'en') return 'english';
      if (c == 'ja' || c == 'jp') return 'japanese';
    }
    return null;
  }

  String? _detectLang(Map<String, dynamic> d) {
    final explicit = _readString(d, [
      'language',
      'lang',
      'audioLanguage',
      'audio',
    ]);
    if (explicit.isNotEmpty) {
      final l = _normLang(explicit, allowShort: true);
      if (l != null) return l;
    }
    return _normLang(_readString(d, ['title', 'name', 'videoTitle']));
  }

  String _groupKey(Map<String, dynamic> d) {
    final explicit = _readString(d, ['langGroup', 'groupId']);
    if (explicit.isNotEmpty) return 'g|$explicit';
    final base = _readString(d, ['title', 'name', 'videoTitle'])
        .toLowerCase()
        .replaceAll(
          RegExp(r'tamil|தமிழ்|english|japanese|\b(tam|eng|jpn|jap|dub|dubbed)\b'),
          ' ',
        )
        .replaceAll(RegExp(r'[^a-z0-9\u0B80-\u0BFF]+'), ' ')
        .trim();
    final season = _readString(d, ['season', 'seasonNumber']);
    final ep = _getEpisodeNumber(d);
    return '${_readString(d, ['category'])}|$season|$ep|$base';
  }

  /// Only the videos that can belong to the same episode group (was: the WHOLE videos collection on every open).
  /// Falls back to the full read if the narrowed query fails.
  Future<QuerySnapshot<Map<String, dynamic>>> _groupCandidates(Map<String, dynamic> data) async {
    final col = FirebaseFirestore.instance.collection('videos');
    try {
      Query<Map<String, dynamic>>? q;
      for (final f in const ['langGroup', 'groupId']) {
        final v = data[f];
        if (v != null && v.toString().trim().isNotEmpty) {
          q = col.where(f, isEqualTo: v);
          break;
        }
      }
      if (q == null) {
        final cat = data['category'];
        if (cat != null && cat.toString().trim().isNotEmpty) {
          var byCat = col.where('category', isEqualTo: cat);
          for (final f in const ['season', 'seasonNumber']) {
            final v = data[f];
            if (v != null && v.toString().trim().isNotEmpty) {
              byCat = byCat.where(f, isEqualTo: v);
              break;
            }
          }
          q = byCat;
        }
      }
      if (q != null) return await q.get();
    } catch (e) {
      debugPrint('Group query failed, reading all videos: $e');
    }
    return col.get();
  }

  Future<void> _loadLanguages(Map<String, dynamic> data) async {
    final id = widget.videoId;
    final found = <String, String>{};
    final curLang = _detectLang(data);

    // (a) one doc holding several urls:  languages: { tamil: url, ... }
    final map = data['languages'];
    if (map is Map) {
      map.forEach((k, v) {
        final l = _normLang(k.toString(), allowShort: true);
        final u = v?.toString().trim() ?? '';
        if (l != null && u.isNotEmpty) found[l] = u;
      });
    }

    // (b) separate docs of the same episode, one per language
    try {
      final snap = await _groupCandidates(data);
      final key = _groupKey(data);
      for (final d in snap.docs) {
        if (d.id == id) continue;
        final dd = d.data();
        if (_groupKey(dd) != key) continue;
        final l = _detectLang(dd);
        final u = _readString(dd, ['videoUrl', 'url', 'videoURL']);
        if (l != null && u.isNotEmpty) found.putIfAbsent(l, () => u);
      }
    } catch (e) {
      debugPrint('LANGUAGE LOOKUP ERROR: $e');
    }

    if (curLang != null) found[curLang] = _videoUrl;

    if (!mounted || id != widget.videoId) return;
    // Only ONE language available -> no switcher at all.
    if (found.length < 2) return;
    setState(() {
      _langUrls = found;
      if (_activeLang.isEmpty) _activeLang = curLang ?? '';
    });
  }

  String? _langFromCode(String raw) {
    final c = raw.toLowerCase().trim().split(RegExp(r'[-_]')).first;
    if (const ['ta', 'tam', 'tamil'].contains(c)) return 'tamil';
    if (const ['en', 'eng', 'english'].contains(c)) return 'english';
    if (const ['ja', 'jp', 'jpn', 'jap', 'japanese'].contains(c)) {
      return 'japanese';
    }
    return null;
  }

  /// Languages stored as audio tracks INSIDE the video file (multi-audio).
  Future<void> _loadAudioTracks({bool retry = true}) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (!c.isAudioTrackSupportAvailable()) {
        _trackDebug = 'Audio track API NOT supported on this platform.';
        return;
      }
      final tracks = await c.getAudioTracks();
      _trackDebug = tracks.isEmpty
          ? 'No audio tracks reported by the player.'
          : tracks
              .map((t) =>
                  'id=${t.id} | lang=${t.language} | label=${t.label} | selected=${t.isSelected}')
              .join('\n');
      debugPrint('AUDIO TRACKS:\n$_trackDebug');
      final map = <String, String>{};
      var sel = '';
      for (final t in tracks) {
        final code = '${t.language}'.trim().toLowerCase();
        final hasCode = code.isNotEmpty && code != 'null' && code != 'und';
        // Language code wins; label is used only when there is no code.
        final l = hasCode ? _langFromCode(code) : _normLang('${t.label}');
        if (l == null) continue;
        map.putIfAbsent(l, () => t.id.toString());
        if (t.isSelected) sel = l;
      }
      if (!mounted || !identical(c, _controller)) return;
      if (map.isEmpty && retry) {
        await Future.delayed(const Duration(seconds: 2));
        return _loadAudioTracks(retry: false);
      }
      // Playing track is not Tamil/English/Japanese (e.g. Hindi) -> switch to
      // the first supported one so audio and highlighted chip match.
      if (sel.isEmpty && map.length >= 2) {
        final pick = _langOrder.firstWhere(map.containsKey);
        try {
          await c.selectAudioTrack(map[pick]!);
          sel = pick;
        } catch (e) {
          debugPrint('AUTO AUDIO SELECT ERROR: $e');
        }
      }
      if (!mounted || !identical(c, _controller)) return;
      setState(() {
        _audioTracks = map;
        if (sel.isNotEmpty) _activeLang = sel;
      });
    } catch (e) {
      debugPrint('AUDIO TRACK ERROR: $e');
    }
  }

  Future<void> _switchLanguage(String lang) async {
    if (lang == _activeLang || _switchingLang) return;

    // Same file, different audio track -> instant switch, no reload.
    final trackId = _audioTracks[lang];
    if (trackId != null && _controller != null) {
      try {
        await _controller!.selectAudioTrack(trackId);
        if (mounted) setState(() => _activeLang = lang);
      } catch (e) {
        debugPrint('AUDIO SWITCH ERROR: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_langLabel[lang]} audio not available.')),
          );
        }
      }
      return;
    }

    final url = _langUrls[lang];
    if (url == null) return;

    final old = _controller;
    final pos = old?.value.position ?? Duration.zero;
    final wasPlaying = old?.value.isPlaying ?? true;

    setState(() => _switchingLang = true);
    old?.removeListener(_videoListener);
    await old?.pause();

    try {
      await _initializeVideo(url, resumeAt: pos); // sets _controller on success
      if (!mounted) return;
      if (!identical(_controller, old)) {
        await old?.dispose();
        if (!wasPlaying) await _controller?.pause();
        _videoUrl = url;
        _activeLang = lang;
        _audioTracks = {};
        _loadAudioTracks();
      }
    } catch (e) {
      debugPrint('LANGUAGE SWITCH ERROR: $e');
      if (!mounted) return;
      _controller = old;
      old?.addListener(_videoListener);
      if (wasPlaying) await old?.play();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_langLabel[lang]} video could not be loaded.'),
        ),
      );
    }

    if (mounted) setState(() => _switchingLang = false);
  }

  void _showTrackDebug() {
    showNeoSheet<void>(
      context,
      title: 'Audio tracks (debug)',
      sub: 'RAW',
      child: SelectableText(
        '$_trackDebug\n\n${StreamPerf.summary()}',
        style: const TextStyle(
          color: Neo.text,
          fontFamily: Neo.mono,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }

  void _showLanguages() {
    showNeoSheet<void>(
      context,
      title: 'Language',
      sub: 'AUDIO',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final l in _langOrder) _langChip(l, closeSheet: true),
        ],
      ),
    );
  }

  Widget _langChip(String lang, {bool closeSheet = false}) {
    final available = _availLangs.contains(lang);
    final selected = lang == _activeLang;
    final color = selected ? Neo.cyan : Neo.muted;
    return GestureDetector(
      onTap: () {
        if (closeSheet) Navigator.pop(context);
        if (!available) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_langLabel[lang]} is not available for this video.')),
          );
          return;
        }
        _switchLanguage(lang);
      },
      child: Opacity(
        opacity: available ? 1 : 0.4,
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 0.18 : 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(
          _langLabel[lang]!,
          style: TextStyle(
            color: color,
            fontFamily: Neo.mono,
            fontWeight: FontWeight.w700,
            fontSize: 12,
            letterSpacing: 1,
          ),
        ),
      ),
      ),
    );
  }

  // ============================================================
  // VIDEO LISTENER
  // ============================================================

  void _videoListener() {
    if (!mounted || _controller == null) {
      return;
    }

    if (_controller!.value.hasError) {
      debugPrint(
        'VideoPlayer error: '
        '${_controller!.value.errorDescription}',
      );
    }

    // Save when the user pauses
    final isPlaying = _controller!.value.isPlaying;
    if (_wasPlaying && !isPlaying) {
      _saveLastWatched();
    }
    _wasPlaying = isPlaying;
    ScreenAwakeService.set(this, isPlaying && _fg); // on only while playing

    // ~60% watched -> get the next episode's player ready in the background
    if (!_preloadStarted && _nextUrl.isNotEmpty) {
      final v = _controller!.value;
      if (v.isInitialized && v.duration.inSeconds > 60 && v.position.inMilliseconds > v.duration.inMilliseconds * 0.3) {
        _preloadStarted = true;
        unawaited(StreamPreload.prepare(_nextUrl, _buildVideoCandidates(_nextUrl)));
      }
    }

    // Episode finished -> automatically play the next one in the playlist.
    // (In fullscreen the fullscreen page pops with 'next' instead.)
    if (!_autoNextDone && !_inFullscreen && !_loading && !_switchingLang && _nextId != null) {
      final v = _controller!.value;
      final ended = v.isInitialized &&
          v.duration > Duration.zero &&
          (v.isCompleted ||
              (!v.isPlaying && v.position >= v.duration - const Duration(milliseconds: 300)));
      if (ended) {
        _autoNextDone = true;
        final id = _nextId;
        Future.microtask(() => _goToVideo(id));
        return;
      }
    }

    if (!_loading) {
      setState(() {});
    }
  }

  // ============================================================
  // LAST WATCHED (Firestore)
  // ============================================================

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_controller?.value.isPlaying == true) {
        _saveLastWatched();
      }
    });
  }

  void _saveLastWatched() {
    final controller = _controller;

    if (controller == null ||
        !controller.value.isInitialized ||
        _title.isEmpty) {
      return;
    }

    final position = controller.value.position;
    final duration = controller.value.duration;

    // Video almost finished -> restart from the beginning next time
    final finished =
        duration > Duration.zero &&
        position >= duration - const Duration(seconds: 10);

    LastWatchedService.save(
      videoId: widget.videoId,
      playlistId: widget.playlistId,
      title: _title,
      thumbnail: _thumbnail,
      positionSeconds: finished ? 0 : position.inSeconds,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _saveLastWatched();
    }

    // Screen-awake: drop in background, re-assert on return (also web tab visible).
    if (state == AppLifecycleState.resumed) {
      _fg = true;
      ScreenAwakeService.set(this, _controller?.value.isPlaying ?? false,
          refresh: true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _fg = false;
      ScreenAwakeService.release(this);
    }
  }

  // ============================================================
  // PLAY / PAUSE
  // ============================================================

  /// Desktop keyboard: Space/K play-pause, <-/-> seek 10s, F fullscreen, Esc back.
  bool _onKey(KeyEvent e) {
    if (e is KeyUpEvent || !mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      _togglePlayPause();
    } else if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyL) {
      _seekBy(const Duration(seconds: 10));
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyJ) {
      _seekBy(const Duration(seconds: -10));
    } else if (k == LogicalKeyboardKey.keyF) {
      _openFullscreen();
    } else if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    } else {
      return false;
    }
    return true;
  }

  Future<void> _togglePlayPause() async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }

    if (mounted) {
      setState(() {});
    }
  }

  // ============================================================
  // SEEK
  // ============================================================

  Future<void> _seekBy(Duration amount) async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final current = controller.value.position;

    final duration = controller.value.duration;

    var target = current + amount;

    if (target < Duration.zero) {
      target = Duration.zero;
    }

    if (target > duration) {
      target = duration;
    }

    await controller.seekTo(target);

    if (mounted) {
      setState(() {});
    }
  }

  // ============================================================
  // PLAYBACK SPEED
  // ============================================================

  Future<void> _changePlaybackSpeed(double speed) async {
    final controller = _controller;

    if (controller == null) {
      return;
    }

    await controller.setPlaybackSpeed(speed);

    if (!mounted) return;

    setState(() {
      _playbackSpeed = speed;
    });
  }

  // ============================================================
  // SETTINGS
  // ============================================================

  void _showSettings() {
    showNeoSheet<void>(
      context,
      title: 'Playback Speed',
      sub: 'SETTINGS',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final speed in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
            _SpeedChip(
              speed: speed,
              selected: (_playbackSpeed - speed).abs() < 0.01,
              onTap: () async {
                await _changePlaybackSpeed(speed);
                if (!mounted) return;
                Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _openFullscreen() async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    if (!mounted) return;

    _inFullscreen = true;
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) {
          return _FullscreenVideoPage(
            controller: controller,
            title: _title,
            playbackSpeed: _playbackSpeed,
            hasPrev: _prevId != null,
            hasNext: _nextId != null,
            langs: [
              for (final l in _langOrder)
                if (_availLangs.contains(l)) l,
            ],
            activeLang: _activeLang,
            audioLangs: _audioTracks.keys.toSet(),
            langLabels: _langLabel,
            langShort: _langShort,
            onAudioSwitch: _switchLanguage,
          );
        },
      ),
    );

    _inFullscreen = false;

    // next / previous from fullscreen: stay landscape, new page opens fullscreen itself
    if (result == 'prev' || result == 'next') {
      _goToVideo(result == 'prev' ? _prevId : _nextId, fullscreen: true);
      return;
    }

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    if (result != null && result.startsWith('lang:')) {
      // Language lives in a different video file -> switch, then re-enter fullscreen.
      await _switchLanguage(result.substring(5));
      if (mounted) _openFullscreen();
      return;
    }

  }

  // ============================================================
  // FORMAT DURATION
  // ============================================================

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;

    final minutes = duration.inMinutes.remainder(60);

    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }

    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // VIDEO PLAYER
  // ============================================================

  Widget _buildVideoPlayer() {
    final controller = _controller;

    // Error is shown ONLY inside the player area (not the whole page).
    if (_hasError) return _buildErrorScreen();

    if (controller == null || !controller.value.isInitialized) {
      // Loading animation lives ONLY inside the player area (not the whole page).
      return _loading ? _buildPlayerLoading() : const ColoredBox(color: Colors.black);
    }

    final width = controller.value.size.width;

    final height = controller.value.size.height;

    double ratio = 16 / 9;

    if (width > 0 && height > 0) {
      ratio = width / height;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          _showControls = !_showControls;
        });
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: MouseRegion(opaque: false, onHover: (_) => _pokeControls()),
          ),
          Container(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: ratio,
                child: VideoPlayer(controller),
              ),
            ),
          ),

          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _showControls ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_showControls,
              child: _buildVideoControls(),
            ),
          ),

          if (_switchingLang)
            const ColoredBox(
              color: Color(0x88000000),
              child: Center(
                child: CircularProgressIndicator(color: Neo.cyan),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // VIDEO CONTROLS
  // ============================================================

  Widget _buildVideoControls() {
    final controller = _controller!;
    final position = controller.value.position;
    final duration = controller.value.duration;

    final durationMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds;
    final safeMax = durationMs <= 0 ? 1 : durationMs;
    final safeValue = positionMs.clamp(0, safeMax).toDouble();
    final playing = controller.value.isPlaying;

    return Stack(
      children: [
        // ---------------- top bar ----------------
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.75),
                  Colors.transparent,
                ],
              ),
            ),
            child: Row(
              children: [
                _controlButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  size: 38,
                  iconSize: 18,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Neo.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ---------------- center buttons ----------------
        Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _controlButton(
                icon: Icons.skip_previous_rounded,
                size: 40,
                iconSize: 24,
                enabled: _prevId != null,
                onTap: () => _goToVideo(_prevId),
              ),
              const SizedBox(width: 12),
              _controlButton(
                icon: Icons.replay_10_rounded,
                size: 46,
                iconSize: 24,
                onTap: () {
                  _seekBy(const Duration(seconds: -10));
                },
              ),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: _togglePlayPause,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Neo.cyan, Neo.violet],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Neo.cyan.withValues(alpha: 0.55),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Neo.bg,
                    size: 36,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              _controlButton(
                icon: Icons.forward_10_rounded,
                size: 46,
                iconSize: 24,
                onTap: () {
                  _seekBy(const Duration(seconds: 10));
                },
              ),
              const SizedBox(width: 12),
              _controlButton(
                icon: Icons.skip_next_rounded,
                size: 40,
                iconSize: 24,
                enabled: _nextId != null,
                onTap: () => _goToVideo(_nextId),
              ),
            ],
          ),
        ),

        // ---------------- bottom bar ----------------
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 14, 8, 4),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.85),
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 22,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      activeTrackColor: Neo.cyan,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Neo.cyan.withValues(alpha: 0.2),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                    ),
                    child: Slider(
                      min: 0,
                      max: safeMax.toDouble(),
                      value: safeValue,
                      onChanged: (value) {
                        controller.seekTo(Duration(milliseconds: value.toInt()));
                      },
                    ),
                  ),
                ),
                SizedBox(
                  height: 38,
                  child: Row(
                    children: [
                      Text(
                        '${_formatDuration(position)} / '
                        '${_formatDuration(duration)}',
                        style: const TextStyle(
                          color: Neo.text,
                          fontFamily: Neo.mono,
                          fontSize: 11.5,
                        ),
                      ),
                      const Spacer(),
                      ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: _showLanguages,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Neo.violet.withValues(alpha: 0.6),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.translate_rounded,
                                      size: 14, color: Neo.violet),
                                  const SizedBox(width: 5),
                                  Text(
                                    _langShort[_activeLang] ?? 'LANG',
                                    style: const TextStyle(
                                      color: Neo.violet,
                                      fontFamily: Neo.mono,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      GestureDetector(
                        onTap: _showSettings,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Neo.cyan.withValues(alpha: 0.6),
                            ),
                          ),
                          child: Text(
                            _fmtSpeed(_playbackSpeed),
                            style: const TextStyle(
                              color: Neo.cyan,
                              fontFamily: Neo.mono,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Fullscreen',
                        onPressed: _openFullscreen,
                        color: Neo.text,
                        icon: const Icon(Icons.fullscreen_rounded, size: 26),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _controlButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 46,
    double iconSize = 24,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: CircleBorder(side: BorderSide(color: Neo.line)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Neo.text, size: iconSize),
          ),
        ),
      ),
    );
  }

  void _goToVideo(String? id, {bool fullscreen = false}) {
    if (id == null || id.isEmpty || !mounted) return;
    // keep the current landscape orientation (fullscreen or landscape page) across the switch
    _keepLandscape =
        fullscreen || (!isWindows && MediaQuery.of(context).orientation == Orientation.landscape);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayPage(
          videoId: id,
          playlistId: widget.playlistId,
          startFullscreen: fullscreen,
        ),
      ),
    );
  }

  /// Loading animation shown only where the video controls will appear (the player area).
  Widget _buildPlayerLoading() {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Neo.cyan),
              SizedBox(height: 12),
              Text(
                'LOADING STREAM',
                style: TextStyle(
                  color: Neo.muted,
                  fontFamily: Neo.mono,
                  fontSize: 11,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 8,
          top: 8,
          child: _controlButton(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 38,
            iconSize: 18,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorScreen() {
    return Container(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, box) {
          final compact = box.maxHeight < 260;
          return Center(
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: 16, vertical: compact ? 6 : 16),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off_rounded,
                          color: Neo.pink, size: compact ? 30 : 46),
                      SizedBox(height: compact ? 4 : 10),
                      const Text(
                        'Unable to play video',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Neo.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _errorMessage.isEmpty
                            ? 'The video could not be loaded.'
                            : _errorMessage,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Neo.muted, fontSize: 12),
                      ),
                      SizedBox(height: compact ? 8 : 14),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 130,
                            child: NeoButton(
                              label: 'RETRY',
                              icon: Icons.refresh_rounded,
                              onTap: _loadPage,
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 130,
                            child: NeoGhostButton(
                              label: 'Go Back',
                              leading: const Icon(Icons.arrow_back_rounded,
                                  color: Neo.text, size: 18),
                              onTap: () => Navigator.pop(context),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _fmtSpeed(double s) => s == s.roundToDouble() ? '${s.toInt()}x' : '${s}x';

  Future<List<String>> _getPlaylistVideoIds() async {
    if (widget.playlistId.trim().isEmpty) {
      return [];
    }

    final playlistRef = FirebaseFirestore.instance
        .collection('playlists')
        .doc(widget.playlistId);

    // ----------------------------------------------------------
    // 1. videoIds ARRAY
    // ----------------------------------------------------------

    try {
      final playlistDoc = await playlistRef.get();

      if (playlistDoc.exists) {
        final data = playlistDoc.data();

        if (data != null) {
          final dynamic videoIds = data['videoIds'];

          if (videoIds is List) {
            final ids = videoIds
                .map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList();

            if (ids.isNotEmpty) {
              return ids;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Playlist document error: $e');
    }

    // ----------------------------------------------------------
    // 2. SUBCOLLECTION
    // ----------------------------------------------------------

    try {
      final subCollection = await playlistRef.collection('videos').get();

      if (subCollection.docs.isNotEmpty) {
        return subCollection.docs
            .map((doc) => doc.id)
            .where((id) => id.isNotEmpty)
            .toList();
      }
    } catch (e) {
      debugPrint('Playlist subcollection error: $e');
    }

    // ----------------------------------------------------------
    // 3. videos WHERE playlistId
    // ----------------------------------------------------------

    try {
      final query = await FirebaseFirestore.instance
          .collection('videos')
          .where('playlistId', isEqualTo: widget.playlistId)
          .get();

      return query.docs
          .map((doc) => doc.id)
          .where((id) => id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Playlist video query error: $e');

      return [];
    }
  }

  // ============================================================
  // GET EPISODE NUMBER
  // ============================================================

  int _getEpisodeNumber(Map<String, dynamic> data) {
    final episode = _readString(data, [
      'episodes',
      'episodeNumber',
      'episode',
      'episodeNo',
      'ep',
    ]);

    if (episode.isEmpty) {
      return 999999;
    }

    // Supports:
    // 1
    // "1"
    // "Episode 1"
    // "EP 10"

    final match = RegExp(r'\d+').firstMatch(episode);

    if (match == null) {
      return 999999;
    }

    return int.tryParse(match.group(0)!) ?? 999999;
  }

  // ============================================================
  // LOAD MORE VIDEOS
  // ============================================================

  static const Set<String> _titleStop = {
    'the', 'a', 'an', 'of', 'and', 'movie', 'film', 'part', 'season', 'dub',
    'dubbed', 'sub', 'tamil', 'english', 'japanese', 'hindi', 'telugu', 'hd',
    'full', 'episode', 'ep', 'new', 'version', 'special',
  };

  Set<String> _titleTokens(String title) => title
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.length >= 2 && int.tryParse(w) == null && !_titleStop.contains(w))
      .toSet();

  /// Standalone movie (no playlist): "up next" = the other movies in RANDOM order,
  /// but movies with a related name (same franchise) come first.
  /// The first one in the list is also the auto-play next movie.
  Future<List<DocumentSnapshot<Map<String, dynamic>>>> _loadMoreMovies() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('videos')
          .where('category', whereIn: const ['movies', 'Movies'])
          .orderBy('createdAt', descending: true)
          .limit(200)
          .get();
      final all = snap.docs.where((d) => d.data()['released'] != false).toList();

      String titleOf(Map<String, dynamic> d) => _readString(d, ['title', 'name', 'videoTitle']);
      String curTitle = _title;
      for (final d in all) {
        if (d.id == widget.videoId) curTitle = titleOf(d.data());
      }
      final curTokens = _titleTokens(curTitle);
      final need = curTokens.length >= 2 ? 2 : 1;
      final random = rnd.Random();

      final related = <(int, double, DocumentSnapshot<Map<String, dynamic>>)>[];
      final others = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final d in all) {
        if (d.id == widget.videoId) continue;
        final shared = curTokens.isEmpty
            ? 0
            : _titleTokens(titleOf(d.data())).intersection(curTokens).length;
        if (curTokens.isNotEmpty && shared >= need) {
          related.add((shared, random.nextDouble(), d));
        } else {
          others.add(d);
        }
      }
      // more shared words first, random inside the same score
      related.sort((a, b) {
        final c = b.$1.compareTo(a.$1);
        return c != 0 ? c : a.$2.compareTo(b.$2);
      });
      others.shuffle(random);

      final list = <DocumentSnapshot<Map<String, dynamic>>>[
        for (final r in related) r.$3,
        ...others,
      ].take(40).toList();

      _prevId = null;
      _nextId = list.isEmpty ? null : list.first.id;
      _nextUrl = list.isEmpty
          ? ''
          : _readString(list.first.data() ?? <String, dynamic>{}, ['videoUrl', 'url', 'videoURL']);
      return list;
    } catch (e) {
      debugPrint('MORE MOVIES ERROR: $e');
      return [];
    }
  }

  Future<List<DocumentSnapshot<Map<String, dynamic>>>> _loadMoreVideos() async {
    if (widget.playlistId.trim().isEmpty) return _loadMoreMovies();
    final videoIds = await _getPlaylistVideoIds();

    if (videoIds.isEmpty) {
      return [];
    }

    // include current video so prev/next can be worked out
    final allIds = <String>{...videoIds, widget.videoId}.toList();

    final List<DocumentSnapshot<Map<String, dynamic>>> results = [];

    // ----------------------------------------------------------
    // LOAD ALL VIDEOS
    // ----------------------------------------------------------

    // all documents in parallel (was one round-trip per video)
    final fetched = await Future.wait(allIds.map((id) async {
      try {
        final doc = await FirebaseFirestore.instance.collection('videos').doc(id).get();
        return doc.exists ? doc : null;
      } catch (e) {
        debugPrint('Could not load video $id: $e');
        return null;
      }
    }));
    results.addAll(fetched.whereType<DocumentSnapshot<Map<String, dynamic>>>());

    // ----------------------------------------------------------
    // SORT ASCENDING BY EPISODE
    // ----------------------------------------------------------

    results.sort((a, b) {
      final aData = a.data() ?? {};
      final bData = b.data() ?? {};

      int seasonOf(Map<String, dynamic> d) =>
          int.tryParse(RegExp(r'\d+').firstMatch(_readString(d, ['season', 'seasonNumber']))?.group(0) ?? '') ?? 0;

      final bySeason = seasonOf(aData).compareTo(seasonOf(bData));
      if (bySeason != 0) return bySeason;

      final aEpisode = _getEpisodeNumber(aData);

      final bEpisode = _getEpisodeNumber(bData);

      final c = aEpisode.compareTo(bEpisode);
      return c != 0 ? c : a.id.compareTo(b.id);
    });

    final cur = results.indexWhere((d) => d.id == widget.videoId);
    _prevId = cur > 0 ? results[cur - 1].id : null;
    _nextId = (cur >= 0 && cur < results.length - 1) ? results[cur + 1].id : null;
    _nextUrl = _nextId == null
        ? ''
        : _readString(results[cur + 1].data() ?? <String, dynamic>{}, ['videoUrl', 'url', 'videoURL']);

    results.removeWhere((d) => d.id == widget.videoId);

    return results;
  }

  // ============================================================
  // PULL TO REFRESH
  // ============================================================

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  /// Throws when offline (server read can't be served from cache).
  Future<DocumentSnapshot<Map<String, dynamic>>> _serverVideoDoc() => FirebaseFirestore.instance
      .collection('videos')
      .doc(widget.videoId)
      .get(const GetOptions(source: Source.server))
      .timeout(const Duration(seconds: 15));

  String _refreshError(Object e) => (e is TimeoutException || e is FirebaseException)
      ? "You're offline or the server is slow. Please try again."
      : "Couldn't refresh. Please try again.";

  Future<bool> _reloadMore() async {
    try {
      final r = await _loadMoreVideos();
      if (!mounted) return false;
      if (r.isEmpty && _moreVideos.isNotEmpty) return false; // keep what the user already sees
      setState(() {
        _moreVideos = r;
        _moreVideosLoaded = true;
      });
      return true;
    } catch (e) {
      debugPrint('MORE VIDEOS REFRESH ERROR: $e');
      return false;
    }
  }

  /// Pull on the More Videos section: reload only that section. Player, position and scroll state stay.
  Future<void> _refreshMore() async {
    if (_refreshing || _refreshingMore || _loading || _hasError) return;
    setState(() => _refreshingMore = true);
    try {
      await _serverVideoDoc();
      if (!await _reloadMore()) _snack("Couldn't refresh More Videos.");
    } catch (e) {
      _snack(_refreshError(e));
    } finally {
      if (mounted) setState(() => _refreshingMore = false);
    }
  }

  /// Pull from the very top: re-sync the whole page (details, languages, More Videos)
  /// WITHOUT re-creating the player, so playback continues.
  Future<void> _refreshPage() async {
    if (_refreshing || _refreshingMore || _loading || _hasError) return;
    _refreshing = true;
    try {
      final doc = await _serverVideoDoc();
      final data = doc.data();
      if (!mounted) return;
      if (!doc.exists || data == null) {
        _snack('This video is no longer available.');
        return;
      }
      setState(() {
        _title = _readString(data, ['title', 'name', 'videoTitle'], fallback: _title);
        _season = _readString(data, ['season', 'seasonNumber']);
        _episode = _readString(data, ['episodes', 'episodeNumber', 'episode', 'episodeNo', 'ep']);
      });
      final ok = await Future.wait([_reloadMore(), _loadLanguages(data).then((_) => true)]);
      if (!ok.first) _snack("Couldn't refresh More Videos.");
    } catch (e) {
      _snack(_refreshError(e));
    } finally {
      _refreshing = false;
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    _feedPull = 0;
    _pullUi.value = 0;
    final ro = _moreKey.currentContext?.findRenderObject();
    var inFeed = false;
    if (ro is RenderBox && ro.attached && ro.hasSize && ro.size.height > 0) {
      inFeed = (ro.localToGlobal(Offset.zero) & ro.size).contains(e.position);
    }
    _feedGesture = inFeed;
  }

  void _onPointerEnd(PointerEvent e) {
    final pulled = _feedPull;
    final feed = _feedGesture;
    _feedPull = 0;
    _pullUi.value = 0;
    if (feed && pulled >= _feedPullTrigger) _refreshMore();
  }

  bool _onFeedScroll(ScrollNotification n) {
    if (n.depth != 0 || !_feedGesture) return false;
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      final over = n.metrics.minScrollExtent - n.metrics.pixels; // > 0 while pulled past the top
      _feedPull = over > 0 ? over : 0;
      _pullUi.value = _feedPull.clamp(0.0, 120.0).toDouble();
    }
    return false;
  }

  Widget _feedPullHint() => ValueListenableBuilder<double>(
        valueListenable: _pullUi,
        builder: (_, v, __) {
          if (v < 8) return const SizedBox.shrink();
          final ready = v >= _feedPullTrigger;
          return Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Neo.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: (ready ? Neo.cyan : Neo.line)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.refresh_rounded, size: 16, color: ready ? Neo.cyan : Neo.muted),
                    const SizedBox(width: 8),
                    Text(ready ? 'Release to refresh More Videos' : 'Pull to refresh More Videos',
                        style: TextStyle(color: ready ? Neo.cyan : Neo.muted, fontSize: 12)),
                  ]),
                ),
              ),
            ),
          );
        },
      );

  // ============================================================
  // LOAD MORE VIDEOS IN BACKGROUND
  // ============================================================

  /// While this episode plays, find the working URL of the next two so they start instantly.
  Future<void> _warmUpNext() async {
    final jobs = <Future<void>>[];
    for (final d in _moreVideos.take(4)) {
      if (!mounted) return;
      final url = _readString(d.data() ?? <String, dynamic>{}, ['videoUrl', 'url', 'videoURL']);
      if (url.isEmpty) continue;
      jobs.add(StreamWarm.url(url, _buildVideoCandidates(url)));
    }
    await Future.wait(jobs);
  }

  Future<void> _loadMoreVideosInBackground() async {
    try {
      final relatedVideos = await _loadMoreVideos();

      if (!mounted) return;

      setState(() {
        _moreVideos = relatedVideos;
        _moreVideosLoaded = true;
      });

      debugPrint('MORE VIDEOS: ${_moreVideos.length}');
      unawaited(_warmUpNext());
    } catch (e) {
      debugPrint('MORE VIDEOS LOAD ERROR: $e');

      if (!mounted) return;

      setState(() {
        _moreVideos = [];
        _moreVideosLoaded = true;
      });
    }
  }

  // ============================================================
  // THUMBNAIL URL
  // ============================================================

  String _getThumbnailUrl(String url) {
    final clean = url.trim();

    if (clean.isEmpty) {
      return '';
    }

    if (!clean.contains('drive.google.com')) {
      return clean;
    }

    final fileId = _extractDriveFileId(clean);

    if (fileId != null && fileId.isNotEmpty) {
      return 'https://drive.google.com/thumbnail'
          '?id=$fileId&sz=w800';
    }

    return clean;
  }

  // ============================================================
  // MORE VIDEOS
  // ============================================================

  Widget _buildRelatedVideos() {
    if (!_moreVideosLoaded || _moreVideos.isEmpty) {
      return const SizedBox.shrink();
    }

    int i = 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'More Videos',
            tag: '${_moreVideos.length} up next',
            color: Neo.violet,
          ),
          if (_refreshingMore)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: const LinearProgressIndicator(minHeight: 3, color: Neo.violet, backgroundColor: Colors.white10),
              ),
            ),
          const SizedBox(height: 14),
          ..._moreVideos.map((doc) {
            final data = doc.data();

            if (data == null) {
              return const SizedBox.shrink();
            }

            final title = _readString(data, [
              'title',
              'name',
              'videoTitle',
            ], fallback: 'Untitled Video');

            final episode = _readString(data, [
              'episodes',
              'episodeNumber',
              'episode',
              'episodeNo',
              'ep',
            ]);

            final thumbnail = _readString(data, [
              'thumbnail',
              'thumbnailUrl',
              'imageUrl',
              'posterUrl',
            ]);

            return FadeIn(
              index: i++,
              child: _buildRelatedVideoCard(doc.id, title, thumbnail, episode),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRelatedVideoCard(
    String id,
    String title,
    String thumbnail,
    String episode,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Tilt3D(
        onTap: () {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) {
                return VideoPlayPage(videoId: id, playlistId: widget.playlistId);
              },
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Neo.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Neo.line),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 132,
                height: 76,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: thumbnail.isNotEmpty
                      ? NeoImage(_getThumbnailUrl(thumbnail))
                      : const ColoredBox(
                          color: Neo.bg2,
                          child: Center(
                            child: Icon(Icons.movie_outlined, color: Neo.muted),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (episode.isNotEmpty) ...[
                      _relatedInfoChip('EP $episode'),
                      const SizedBox(height: 6),
                    ],
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Neo.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.play_circle_outline_rounded, color: Neo.cyan),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _relatedInfoChip(String text) => NeoTag(text, color: Neo.cyan);

  Widget _buildVideoInfo() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // round download button on the LEFT, title + chips on its right
              DownloadButton(
                key: ValueKey('dl_${widget.videoId}_$_activeLang'),
                videoId: widget.videoId,
                variant: _langUrls.length >= 2 ? _activeLang : '',
                url: _videoUrl,
                title: _title,
                subtitle: [
                  if (_season.isNotEmpty) 'S$_season',
                  if (_episode.isNotEmpty) 'EP $_episode',
                  if (_langUrls.length >= 2 && _activeLang.isNotEmpty) (_langShort[_activeLang] ?? ''),
                ].where((e) => e.isNotEmpty).join(' · '),
                thumbnail: _thumbnail,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onLongPress: _showTrackDebug, // long-press title = raw audio track list
                      child: Text(
                        _title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Neo.text,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_season.isNotEmpty) _infoChip('SEASON $_season', Neo.violet),
                        if (_episode.isNotEmpty) _infoChip('EP $_episode', Neo.cyan),
                        _infoChip('SPEED ${_fmtSpeed(_playbackSpeed)}', Neo.amber),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.translate_rounded,
                    size: 16, color: Neo.violet),
                for (final l in _langOrder) _langChip(l),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoChip(String text, Color color) => NeoTag(text, color: color);

  @override
  Widget build(BuildContext context) {
    // A Windows window is always wider than tall: never use the phone "landscape = bare player" page there,
    // otherwise the title, Download button, language chips and More Videos list disappear.
    final isLandscape =
        !isWindows && MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: Neo.bg,
      body: LayoutBuilder(
        builder: (context, c) {
          if (Bp.isDesktop(c.maxWidth) && c.maxHeight >= 520) {
            return _buildDesktopPage(c.maxWidth, c.maxHeight);
          }
          return isLandscape ? _buildLandscapePage() : _buildPortraitPage();
        },
      ),
    );
  }

  Widget _buildDesktopPage(double w, double h) {
    final side = w >= 1300 ? 420.0 : 360.0;
    final playerW = ((h - 140) * 16 / 9).clamp(480.0, w - side);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(children: [
        GlassIconButton(
          icon: Icons.arrow_back_ios_new_rounded,
          onTap: () => Navigator.of(context).maybePop(),
        ),
      ]),
    );
    return SafeArea(
      child: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                header,
                const SizedBox(height: 10),
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: playerW),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                              color: Neo.cyan.withValues(alpha: 0.16),
                              blurRadius: 30,
                              offset: const Offset(0, 8)),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: AspectRatio(aspectRatio: 16 / 9, child: _buildVideoPlayer()),
                    ),
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: playerW),
                      child: ListView(
                        children: [if (_title.isNotEmpty) _buildVideoInfo()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: side,
            decoration: BoxDecoration(
              color: Neo.bg2.withValues(alpha: 0.7),
              border: Border(left: BorderSide(color: Neo.line)),
            ),
            child: ListView(children: [_buildRelatedVideos()]),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitPage() {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWindows ? 1100 : 960),
          child: Column(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  boxShadow: [
                    BoxShadow(
                      color: Neo.cyan.withValues(alpha: 0.16),
                      blurRadius: 30,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _buildVideoPlayer(),
                ),
              ),
              Expanded(
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerUp: _onPointerEnd,
                  onPointerCancel: _onPointerEnd,
                  child: Stack(children: [
                    NotificationListener<ScrollNotification>(
                      onNotification: _onFeedScroll,
                      child: NeoRefresh(
                        onRefresh: _refreshPage,
                        // a pull that began on the More Videos section is NOT a full-page refresh
                        notificationPredicate: (n) => n.depth == 0 && !_feedGesture,
                        child: ListView(
                          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                          children: [
                            if (_title.isNotEmpty) _buildVideoInfo(),
                            Container(key: _moreKey, child: _buildRelatedVideos()),
                          ],
                        ),
                      ),
                    ),
                    _feedPullHint(),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapePage() {
    return SizedBox.expand(child: _buildVideoPlayer());
  }
}

class _FullscreenVideoPage extends StatefulWidget {
  final VideoPlayerController controller;
  final String title;
  final double playbackSpeed;
  final bool hasPrev;
  final bool hasNext;
  final List<String> langs;
  final String activeLang;
  final Set<String> audioLangs;
  final Map<String, String> langLabels;
  final Map<String, String> langShort;
  final Future<void> Function(String) onAudioSwitch;

  const _FullscreenVideoPage({
    required this.controller,
    required this.title,
    required this.playbackSpeed,
    required this.langs,
    required this.activeLang,
    required this.audioLangs,
    required this.langLabels,
    required this.langShort,
    required this.onAudioSwitch,
    this.hasPrev = false,
    this.hasNext = false,
  });

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  bool _showControls = true;
  Timer? _ctlTimer;

  void _pokeControls() {
    if (!_showControls && mounted) setState(() => _showControls = true);
    _ctlTimer?.cancel();
    _ctlTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (widget.controller.value.isPlaying)) setState(() => _showControls = false);
    });
  }


  late double _speed;
  late String _lang;

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);

    _speed = widget.playbackSpeed;
    _lang = widget.activeLang;

    widget.controller.addListener(_videoListener);
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _ctlTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    widget.controller.removeListener(_videoListener);

    super.dispose();
  }

  // ============================================================
  // LISTENER
  // ============================================================

  bool _autoNextSent = false;

  void _videoListener() {
    if (!mounted) return;

    // Episode ended while in fullscreen -> hand 'next' back to the player page.
    final v = widget.controller.value;
    if (!_autoNextSent &&
        widget.hasNext &&
        v.isInitialized &&
        v.duration > Duration.zero &&
        (v.isCompleted ||
            (!v.isPlaying && v.position >= v.duration - const Duration(milliseconds: 300)))) {
      _autoNextSent = true;
      Future.microtask(() {
        if (mounted) Navigator.pop(context, 'next');
      });
      return;
    }

    setState(() {});
  }

  // ============================================================
  // FORMAT TIME
  // ============================================================

  String _formatTime(Duration duration) {
    final hours = duration.inHours;

    final minutes = duration.inMinutes.remainder(60);

    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }

    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // PLAY / PAUSE
  // ============================================================

  bool _onKey(KeyEvent e) {
    if (e is KeyUpEvent || !mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      _togglePlayPause();
    } else if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyL) {
      _seekBy(const Duration(seconds: 10));
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyJ) {
      _seekBy(const Duration(seconds: -10));
    } else if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.keyF) {
      Navigator.pop(context);
    } else {
      return false;
    }
    return true;
  }

  Future<void> _togglePlayPause() async {
    final controller = widget.controller;

    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }

    if (mounted) {
      setState(() {});
    }
  }

  // ============================================================
  // SEEK
  // ============================================================

  Future<void> _seekBy(Duration amount) async {
    final controller = widget.controller;

    final position = controller.value.position;

    final duration = controller.value.duration;

    var target = position + amount;

    if (target < Duration.zero) {
      target = Duration.zero;
    }

    if (target > duration) {
      target = duration;
    }

    await controller.seekTo(target);

    if (mounted) {
      setState(() {});
    }
  }

  // ============================================================
  // SPEED
  // ============================================================

  Future<void> _changeSpeed(double speed) async {
    await widget.controller.setPlaybackSpeed(speed);

    if (!mounted) return;

    setState(() {
      _speed = speed;
    });
  }

  // ============================================================
  // SPEED SETTINGS
  // ============================================================

  void _showSpeedSettings() {
    showNeoSheet<void>(
      context,
      title: 'Playback Speed',
      sub: 'SETTINGS',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final speed in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
            _SpeedChip(
              speed: speed,
              selected: (_speed - speed).abs() < 0.01,
              onTap: () async {
                await _changeSpeed(speed);
                if (!mounted) return;
                Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }

  void _showLanguageSheet() {
    showNeoSheet<void>(
      context,
      title: 'Language',
      sub: 'AUDIO',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final l in widget.langs)
            GestureDetector(
              onTap: () async {
                Navigator.pop(context); // close sheet
                if (l == _lang) return;
                if (widget.audioLangs.contains(l)) {
                  await widget.onAudioSwitch(l); // same file, instant
                  if (mounted) setState(() => _lang = l);
                } else {
                  Navigator.pop(context, 'lang:$l'); // other file -> parent
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: (l == _lang ? Neo.cyan : Neo.muted)
                      .withValues(alpha: l == _lang ? 0.18 : 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: (l == _lang ? Neo.cyan : Neo.muted)
                        .withValues(alpha: 0.6),
                  ),
                ),
                child: Text(
                  widget.langLabels[l]!,
                  style: TextStyle(
                    color: l == _lang ? Neo.cyan : Neo.muted,
                    fontFamily: Neo.mono,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _playButton() {
    return GestureDetector(
      onTap: _togglePlayPause,
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [Neo.cyan, Neo.violet],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: Neo.cyan.withValues(alpha: 0.55),
              blurRadius: 26,
            ),
          ],
        ),
        child: Icon(
          widget.controller.value.isPlaying
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          color: Neo.bg,
          size: 40,
        ),
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback? onTap) {
    return Opacity(
      opacity: onTap == null ? 0.35 : 1,
      child: Material(
      color: Colors.black.withValues(alpha: 0.5),
      shape: CircleBorder(side: BorderSide(color: Neo.line)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 50,
          height: 50,
          child: Icon(icon, color: Neo.text, size: 28),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final duration = controller.value.duration;
    final position = controller.value.position;

    final durationMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds;
    final safeMax = durationMs <= 0 ? 1 : durationMs;
    final safeValue = positionMs.clamp(0, safeMax).toDouble();

    final width = controller.value.size.width;
    final height = controller.value.size.height;

    double ratio = 16 / 9;
    if (width > 0 && height > 0) {
      ratio = width / height;
    }

    final speedText =
        _speed == _speed.roundToDouble() ? '${_speed.toInt()}x' : '${_speed}x';

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            _showControls = !_showControls;
          });
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
            child: MouseRegion(opaque: false, onHover: (_) => _pokeControls()),
          ),
            Center(
              child: AspectRatio(
                aspectRatio: ratio,
                child: VideoPlayer(controller),
              ),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _showControls ? 1 : 0,
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Stack(
                  children: [
                    // top bar: back + title
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.8),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => Navigator.pop(context),
                              color: Neo.text,
                              icon: const Icon(Icons.arrow_back_ios_new_rounded),
                            ),
                            Expanded(
                              child: Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Neo.text,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _circleButton(
                            Icons.skip_previous_rounded,
                            widget.hasPrev ? () => Navigator.pop(context, 'prev') : null,
                          ),
                          const SizedBox(width: 20),
                          _circleButton(Icons.replay_10_rounded, () {
                            _seekBy(const Duration(seconds: -10));
                          }),
                          const SizedBox(width: 28),
                          _playButton(),
                          const SizedBox(width: 28),
                          _circleButton(Icons.forward_10_rounded, () {
                            _seekBy(const Duration(seconds: 10));
                          }),
                          const SizedBox(width: 20),
                          _circleButton(
                            Icons.skip_next_rounded,
                            widget.hasNext ? () => Navigator.pop(context, 'next') : null,
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(18, 28, 14, 8),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.88),
                            ],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                activeTrackColor: Neo.cyan,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                                overlayColor: Neo.cyan.withValues(alpha: 0.2),
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7,
                                ),
                              ),
                              child: Slider(
                                min: 0,
                                max: safeMax.toDouble(),
                                value: safeValue,
                                onChanged: (value) {
                                  controller.seekTo(
                                    Duration(milliseconds: value.toInt()),
                                  );
                                },
                              ),
                            ),
                            Row(
                              children: [
                                IconButton(
                                  onPressed: _togglePlayPause,
                                  color: Neo.text,
                                  icon: Icon(
                                    controller.value.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                ),
                                Text(
                                  '${_formatTime(position)} / ${_formatTime(duration)}',
                                  style: const TextStyle(
                                    color: Neo.text,
                                    fontFamily: Neo.mono,
                                    fontSize: 12,
                                  ),
                                ),
                                const Spacer(),
                                ...[
                                  GestureDetector(
                                    onTap: widget.langs.length >= 2
                                        ? _showLanguageSheet
                                        : () => ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Only one language is available for this video.')),
                                            ),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color:
                                              Neo.violet.withValues(alpha: 0.6),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.translate_rounded,
                                              size: 15, color: Neo.violet),
                                          const SizedBox(width: 5),
                                          Text(
                                            widget.langShort[_lang] ?? 'LANG',
                                            style: const TextStyle(
                                              color: Neo.violet,
                                              fontFamily: Neo.mono,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                GestureDetector(
                                  onTap: _showSpeedSettings,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: Neo.cyan.withValues(alpha: 0.6),
                                      ),
                                    ),
                                    child: Text(
                                      speedText,
                                      style: const TextStyle(
                                        color: Neo.cyan,
                                        fontFamily: Neo.mono,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                IconButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                  },
                                  color: Neo.text,
                                  icon: const Icon(Icons.fullscreen_exit_rounded),
                                ),
                              ],
                            ),
                          ],
                        ),
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
}

class _SpeedChip extends StatelessWidget {
  final double speed;
  final bool selected;
  final VoidCallback onTap;

  const _SpeedChip({
    required this.speed,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label =
        speed == speed.roundToDouble() ? '${speed.toInt()}x' : '${speed}x';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 76,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: selected
              ? const LinearGradient(colors: [Neo.cyan, Neo.violet])
              : null,
          color: selected ? null : Colors.black.withValues(alpha: 0.28),
          border: Border.all(color: selected ? Neo.cyan : Neo.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Neo.bg : Neo.text,
            fontFamily: Neo.mono,
            fontWeight: FontWeight.w800,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
} 