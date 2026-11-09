import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../services/download_service.dart';
import '../services/last_watched_service.dart';
import '../services/session_service.dart';
import '../ui/media.dart';
import '../ui/desktop.dart';
import '../ui/neo.dart';
import 'search.dart';
import 'playlist_videos.dart';
import 'profile.dart';
import 'series.dart';
import 'movies.dart';
import 'save_list.dart';
import 'downloads.dart';
import 'video_play.dart';
import '../ui/save_menu.dart';

// ============================================================================
// HOME SHELL (background + tabs + bottom nav + continue watching)
// ============================================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int currentIndex = 0;
  static bool _continuePopupShown = false;

  @override
  void initState() {
    super.initState();
    DownloadService.openDownloadsTab.addListener(_openDownloads);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (DownloadService.openDownloadsPending) {
        _continuePopupShown = true; // opened from a download notification: go straight to Downloads
        _openDownloads();
        return;
      }
      _showContinueWatchingPopup();
    });
  }

  @override
  void dispose() {
    DownloadService.openDownloadsTab.removeListener(_openDownloads);
    super.dispose();
  }

  /// Download notification tapped -> close anything on top (player...) and show the Downloads tab.
  void _openDownloads() {
    if (!mounted) return;
    final nav = SessionService.navigatorKey.currentState;
    if (nav == null) {
      // navigator not ready yet (cold start) -> try again on the next frame
      WidgetsBinding.instance.addPostFrameCallback((_) => _openDownloads());
      return;
    }
    DownloadService.openDownloadsPending = false;
    // from ANY screen (player, profile, a dialog, a bottom sheet ...): close everything on top first
    nav.popUntil((route) => route.isFirst);
    setState(() => currentIndex = 4);
  }

  Future<void> _showContinueWatchingPopup() async {
    if (_continuePopupShown) return;
    _continuePopupShown = true;

    final last = await LastWatchedService.load();
    if (last == null || !mounted) return;

    final resume = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: GlassCard(
              radius: 24,
              borderColor: Neo.cyan.withValues(alpha: 0.4),
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'CONTINUE WATCHING',
                    style: TextStyle(
                      color: Neo.cyan,
                      fontFamily: Neo.mono,
                      fontSize: 11,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: NeoImage(last.thumbnail),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    last.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Neo.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (last.positionSeconds > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Resume from ${_formatPosition(last.position)}',
                      style: const TextStyle(color: Neo.muted, fontSize: 12.5),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 50,
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(dialogContext, false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Neo.muted,
                              side: BorderSide(color: Neo.line),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text('Not now'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: NeoButton(
                          label: 'CONTINUE',
                          icon: Icons.play_arrow_rounded,
                          onTap: () => Navigator.pop(dialogContext, true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (resume == true && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayPage(
            videoId: last.videoId,
            playlistId: last.playlistId,
            startAt: last.position,
          ),
        ),
      );
    }
  }

  String _formatPosition(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final sec = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  @override
  Widget build(BuildContext context) {
    // Users the admin blocked from downloads do not get the Downloads tab (page index 4).
    return ValueListenableBuilder<bool>(
      valueListenable: SessionService.downloadsBlocked,
      builder: (context, blocked, _) {
        final tabs = blocked ? const [0, 1, 2, 3, 5] : const [0, 1, 2, 3, 4, 5];
        final shown = tabs.contains(currentIndex) ? currentIndex : 0;
        final pages = IndexedStack(
          index: shown,
          children: const [
            _HomeContent(),
            SeriesPage(),
            MoviesPage(),
            SavedPage(),
            DownloadsPage(),
            ProfilePage(),
          ],
        );
        return LayoutBuilder(
          builder: (context, c) {
            final desk = Bp.isDesktop(c.maxWidth);
            return Scaffold(
              body: NeoBackground(
                child: desk
                    ? Row(
                        children: [
                          DesktopSideNav(
                            index: shown,
                            tabs: tabs,
                            items: _NeoNavBar._items,
                            onChanged: (i) => setState(() => currentIndex = i),
                          ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: Bp.content(c.maxWidth)),
                                child: SafeArea(bottom: false, child: pages),
                              ),
                            ),
                          ),
                        ],
                      )
                    : SafeArea(bottom: false, child: pages),
              ),
              bottomNavigationBar: desk
                  ? null
                  : _NeoNavBar(
                      index: shown,
                      tabs: tabs,
                      onChanged: (i) => setState(() => currentIndex = i),
                    ),
            );
          },
        );
      },
    );
  }
}

// ============================================================================
// BOTTOM NAV
// ============================================================================

class _NeoNavBar extends StatelessWidget {
  final int index;
  final List<int> tabs; // page indexes that are shown (Downloads can be hidden)
  final ValueChanged<int> onChanged;
  const _NeoNavBar({required this.index, required this.tabs, required this.onChanged});

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.video_library_outlined, Icons.video_library_rounded, 'Series'),
    (Icons.movie_outlined, Icons.movie_rounded, 'Movies'),
    (Icons.bookmark_border_rounded, Icons.bookmark_rounded, 'Saved'),
    (Icons.download_outlined, Icons.download_rounded, 'Downloads'),
    (Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Neo.bg2,
        border: Border(top: BorderSide(color: Neo.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: List.generate(tabs.length, (n) {
              final i = tabs[n];
              final sel = i == index;
              final it = _items[i];
              return Expanded(
                child: InkWell(
                  onTap: () => onChanged(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: sel ? Neo.cyan.withValues(alpha: 0.16) : Colors.transparent,
                          boxShadow: sel
                              ? [BoxShadow(color: Neo.cyan.withValues(alpha: 0.25), blurRadius: 14)]
                              : null,
                        ),
                        child: Icon(
                          sel ? it.$2 : it.$1,
                          size: 23,
                          color: sel ? Neo.cyan : Neo.muted,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        it.$3.toUpperCase(),
                        style: TextStyle(
                          fontFamily: Neo.mono,
                          fontSize: 9,
                          letterSpacing: 0.4,
                          color: sel ? Neo.cyan : Neo.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// HOME CONTENT
// ============================================================================

class _HomeContent extends StatefulWidget {
  const _HomeContent();

  @override
  State<_HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<_HomeContent> {
  static const int _perType = 12;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  late Future<List<_HomeItem>> _future = _loadHomeItems();

  Future<void> _reload() async {
    final f = _loadHomeItems();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  Future<List<_HomeItem>> _loadHomeItems() async {
    final results = await Future.wait([
      _firestore
          .collection('videos')
          .where('category', whereIn: const ['movies', 'Movies'])
          .orderBy('createdAt', descending: true)
          .limit(_perType)
          .get(),
      _firestore
          .collection('playlists')
          .orderBy('createdAt', descending: true)
          .limit(_perType)
          .get(),
    ]);

    final items = <_HomeItem>[
      for (final d in results[0].docs)
        if (d.data()['released'] != false)
          _HomeItem(id: d.id, isMovie: true, data: d.data()),
      for (final d in results[1].docs)
        _HomeItem(id: d.id, isMovie: false, data: d.data()),
    ];
    items.sort((a, b) => createdAtOf(b.data).compareTo(createdAtOf(a.data)));
    return items;
  }

  void _open(_HomeItem item) {
    final title = titleOf(item.data, item.isMovie ? 'Untitled Movie' : 'Untitled Series');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => item.isMovie
            ? VideoPlayPage(videoId: item.id, playlistId: '')
            : PlaylistVideosPage(playlistId: item.id, playlistName: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final spec = GridSpec.of(c.maxWidth);
        return RefreshIndicator(
          color: Neo.cyan,
          backgroundColor: Neo.surface,
          onRefresh: _reload,
          child: FutureBuilder<List<_HomeItem>>(
            future: _future,
            builder: (context, snap) {
              final loading = snap.connectionState == ConnectionState.waiting;

              final header = SliverToBoxAdapter(
                child: PageHeader(
                  overline: 'Stream // Home',
                  title: Neo.appName,
                  pad: spec.pad,
                  trailing: GlassIconButton(
                    icon: Icons.search_rounded,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SearchPage()),
                    ),
                  ),
                ),
              );

              if (loading) {
                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    header,
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: spec.pad),
                        child: AspectRatio(
                          aspectRatio: 16 / 10,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: const Shimmer(),
                          ),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 22)),
                    SkeletonGrid(spec: spec),
                  ],
                );
              }

              if (snap.hasError) {
                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    header,
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: ErrorState(
                        text: 'Unable to load home content',
                        onRetry: _reload,
                      ),
                    ),
                  ],
                );
              }

              final items = snap.data ?? [];
              if (items.isEmpty) {
                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    header,
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.movie_filter_outlined,
                        text: 'No content available',
                        sub: 'Pull down to refresh',
                      ),
                    ),
                  ],
                );
              }

              final hero = items.first;
              final rest = items.skip(1).toList();

              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  header,
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: spec.pad),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: FadeIn(
                            index: 0,
                            child: _HeroCard(item: hero, onTap: () => _open(hero)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (rest.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(spec.pad, 26, spec.pad, 14),
                        child: SectionHeader(
                          title: 'Latest Drops',
                          tag: '${rest.length} titles',
                          color: Neo.cyan,
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.symmetric(horizontal: spec.pad),
                      sliver: SliverGrid(
                        gridDelegate: spec.delegate,
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final it = rest[i];
                            final isM = it.isMovie;
                            return FadeIn(
                              index: i,
                              child: PosterCard(
                                title: titleOf(it.data, isM ? 'Untitled Movie' : 'Untitled Series'),
                                thumb: thumbOf(it.data),
                                badge: isM ? 'MOVIE' : 'SERIES',
                                badgeColor: isM ? Neo.pink : Neo.cyan,
                                sub: it.data['description']?.toString().trim(),
                                icon: isM ? Icons.play_arrow_rounded : Icons.list_rounded,
                                saveCollection: isM ? 'videos' : 'playlists',
                                saveId: it.id,
                                saved: isSavedData(it.data, isM ? 'videos' : 'playlists'),
                                onTap: () => _open(it),
                              ),
                            );
                          },
                          childCount: rest.length,
                        ),
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          'STREAM CORE // END OF FEED',
                          style: TextStyle(
                            color: Neo.muted,
                            fontFamily: Neo.mono,
                            fontSize: 10,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

// ============================================================================
// HERO
// ============================================================================

class _HeroCard extends StatelessWidget {
  final _HomeItem item;
  final VoidCallback onTap;
  const _HeroCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isM = item.isMovie;
    final col = isM ? Neo.pink : Neo.cyan;
    final title = titleOf(item.data, isM ? 'Untitled Movie' : 'Untitled Series');
    final desc = item.data['description']?.toString().trim() ?? '';

    return AspectRatio(
      aspectRatio: 16 / 10,
      child: Tilt3D(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: col.withValues(alpha: 0.28)),
            boxShadow: [
              BoxShadow(color: col.withValues(alpha: 0.12), blurRadius: 30, offset: const Offset(0, 12)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(23),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    0.85, 0, 0, 0, 20,
                    0, 0.85, 0, 0, 20,
                    0, 0, 0.85, 0, 20,
                    0, 0, 0, 1, 0,
                  ]),
                  child: NeoImage(thumbOf(item.data)),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x22080A14), Color(0xB3080A14)],
                      stops: [0.35, 1],
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  child: Row(
                    children: [
                      NeoTag('NEW', color: Neo.amber),
                      const SizedBox(width: 6),
                      NeoTag(isM ? 'MOVIE' : 'SERIES', color: col),
                    ],
                  ),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: SaveMenuButton(
                    collection: isM ? 'videos' : 'playlists',
                    docId: item.id,
                    saved: isSavedData(item.data, isM ? 'videos' : 'playlists'),
                  ),
                ),
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Neo.violet.withValues(alpha: 0.6),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
                      boxShadow: [
                        BoxShadow(color: Neo.violet.withValues(alpha: 0.35), blurRadius: 16),
                      ],
                    ),
                    child: Icon(
                      isM ? Icons.play_arrow_rounded : Icons.list_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 72,
                  bottom: 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                        ),
                      ),
                      if (desc.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          desc,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Neo.muted, fontSize: 12.5),
                        ),
                      ],
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
}

class _HomeItem {
  final String id;
  final bool isMovie;
  final Map<String, dynamic> data;
  const _HomeItem({required this.id, required this.isMovie, required this.data});
}
