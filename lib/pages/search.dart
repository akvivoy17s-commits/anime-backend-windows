import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../ui/media.dart';
import '../ui/desktop.dart';
import '../ui/neo.dart';
import '../ui/refresh.dart';
import 'video_play.dart';
import 'playlist_videos.dart';
import '../ui/save_menu.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _videos = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _playlists = [];
  bool _loading = true;
  bool _error = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final q = _controller.text.trim().toLowerCase();
      if (q != _query) setState(() => _query = q);
    });
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Loaded ONCE, filtered locally (original re-subscribed on every keystroke)
  Future<void> _load({bool silent = false}) async {
    setState(() {
      _loading = !silent;
      _error = false;
    });
    try {
      final db = FirebaseFirestore.instance;
      final res = await Future.wait([
        db.collection('videos').get(),
        db.collection('playlists').get(),
      ]);
      if (!mounted) return;
      setState(() {
        _videos = res[0].docs.where((d) {
          final cat = (d.data()['category'] ?? '').toString().trim().toLowerCase();
          return cat == 'movies' && d.data()['released'] != false;
        }).toList();
        _playlists = res[1].docs;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Search load error: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  bool _m(Object? v) => v != null && v.toString().toLowerCase().contains(_query);

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _videoHits {
    if (_query.isEmpty) return const [];
    return _videos.where((d) {
      final x = d.data();
      return _m(x['title'] ?? x['name'] ?? x['videoTitle']) ||
          _m(x['season']) ||
          _m(x['episodes'] ?? x['episode']);
    }).toList();
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _playlistHits {
    if (_query.isEmpty) return const [];
    return _playlists.where((d) {
      final x = d.data();
      return _m(x['name'] ?? x['title'] ?? x['playlistName']);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final vh = _videoHits;
    final ph = _playlistHits;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator(color: Neo.cyan));
    } else if (_error) {
      body = ErrorState(text: 'Unable to load search data', onRetry: _load);
    } else if (_query.isEmpty) {
      body = const EmptyState(
        icon: Icons.travel_explore_rounded,
        text: 'Search the archive',
        sub: 'Find movies and series by title, season or episode',
      );
    } else if (vh.isEmpty && ph.isEmpty) {
      body = EmptyState(
        icon: Icons.search_off_rounded,
        text: 'Nothing found',
        sub: 'No results for "${_controller.text.trim()}"',
      );
    } else {
      body = NeoRefresh(onRefresh: () => _load(silent: true), child: ListView(
physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          if (vh.isNotEmpty) ...[
            SectionHeader(title: 'Movies', tag: '${vh.length} found', color: Neo.pink),
            const SizedBox(height: 12),
            for (int i = 0; i < vh.length; i++)
              FadeIn(
                index: i,
                child: _ResultTile(
                  title: titleOf(vh[i].data(), 'Untitled Movie'),
                  thumb: thumbOf(vh[i].data()),
                  badge: 'MOVIE',
                  color: Neo.pink,
                  saveCollection: 'videos',
                  saveId: vh[i].id,
                  saved: isSavedData(vh[i].data(), 'videos'),
                  sub: _sub(vh[i].data()),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => VideoPlayPage(
                        videoId: vh[i].id,
                        playlistId: vh[i].data()['playlistId']?.toString() ?? '',
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 20),
          ],
          if (ph.isNotEmpty) ...[
            SectionHeader(title: 'Series', tag: '${ph.length} found', color: Neo.cyan),
            const SizedBox(height: 12),
            for (int i = 0; i < ph.length; i++)
              FadeIn(
                index: i,
                child: _ResultTile(
                  title: titleOf(ph[i].data(), 'Untitled Series'),
                  thumb: thumbOf(ph[i].data()),
                  badge: 'SERIES',
                  color: Neo.cyan,
                  saveCollection: 'playlists',
                  saveId: ph[i].id,
                  saved: isSavedData(ph[i].data(), 'playlists'),
                  sub: ph[i].data()['description']?.toString().trim() ?? '',
                  icon: Icons.list_rounded,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PlaylistVideosPage(
                        playlistId: ph[i].id,
                        playlistName: titleOf(ph[i].data(), 'Untitled Series'),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ));
    }

    return Scaffold(
      body: NeoBackground(
        child: SafeArea(
          child: Column(
            children: [
              CenterMax(child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 16, 14),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Neo.text, size: 20),
                    ),
                    Expanded(
                      child: NeoSearchField(
                        controller: _controller,
                        hint: 'Search movies or series...',
                        autofocus: true,
                      ),
                    ),
                  ],
                ),
              )),
              Expanded(child: CenterMax(child: body)),
            ],
          ),
        ),
      ),
    );
  }

  String _sub(Map<String, dynamic> d) {
    final s = d['season']?.toString().trim() ?? '';
    final e = (d['episodes'] ?? d['episode'])?.toString().trim() ?? '';
    final parts = [if (s.isNotEmpty) 'S$s', if (e.isNotEmpty) 'EP $e'];
    return parts.isEmpty ? (d['description']?.toString().trim() ?? '') : parts.join(' · ');
  }
}

class _ResultTile extends StatelessWidget {
  final String title;
  final String thumb;
  final String badge;
  final String sub;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;
  final String? saveCollection;
  final String? saveId;
  final bool saved;

  const _ResultTile({
    required this.title,
    required this.thumb,
    required this.badge,
    required this.sub,
    required this.color,
    required this.onTap,
    this.icon = Icons.play_arrow_rounded,
    this.saveCollection,
    this.saveId,
    this.saved = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Neo.glass,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Neo.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(width: 96, height: 62, child: NeoImage(thumb)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      NeoTag(badge, color: color),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Neo.text,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (sub.isNotEmpty)
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Neo.muted, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                if (saveCollection != null && saveId != null) ...[
                  SaveMenuButton(collection: saveCollection!, docId: saveId!, saved: saved),
                  const SizedBox(width: 8),
                ],
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.16),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
