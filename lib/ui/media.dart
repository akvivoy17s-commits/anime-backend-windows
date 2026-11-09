import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'neo.dart';
import 'save_menu.dart';

// ===========================================================================
// DATA HELPERS (single copy, replaces the duplicates in every page)
// ===========================================================================

final RegExp _filePat = RegExp(r'/file/d/([a-zA-Z0-9_-]+)');
final RegExp _idPat = RegExp(r'[?&]id=([a-zA-Z0-9_-]+)');

String driveThumb(String url) {
  final u = url.trim();
  if (u.isEmpty) return '';
  if (u.contains('drive.google.com/thumbnail')) return u;
  final m = _filePat.firstMatch(u) ?? _idPat.firstMatch(u);
  if (m != null) {
    return 'https://drive.google.com/thumbnail?id=${m.group(1)}&sz=w1000';
  }
  return u;
}

String thumbOf(Map<String, dynamic> d) {
  for (final k in const ['thumbnailUrl', 'thumbnail', 'imageUrl', 'posterUrl']) {
    final v = d[k]?.toString().trim() ?? '';
    if (v.isNotEmpty) return driveThumb(v);
  }
  return '';
}

String titleOf(Map<String, dynamic> d, String fallback) {
  for (final k in const ['title', 'name', 'videoTitle', 'playlistName']) {
    final v = d[k]?.toString().trim() ?? '';
    if (v.isNotEmpty) return v;
  }
  return fallback;
}

/// True when [q] (already trimmed + lowercase) appears in the title, name or
/// description of a document. Empty query matches everything.
bool matchesQuery(Map<String, dynamic> d, String q) {
  if (q.isEmpty) return true;
  for (final k in const ['title', 'name', 'videoTitle', 'playlistName', 'description']) {
    if ((d[k]?.toString().toLowerCase() ?? '').contains(q)) return true;
  }
  return false;
}

DateTime createdAtOf(Map<String, dynamic> d) {
  final v = d['createdAt'];
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0);
  return DateTime.fromMillisecondsSinceEpoch(0);
}

// ===========================================================================
// RESPONSIVE GRID
// ===========================================================================

class GridSpec {
  final int cols;
  final double pad;
  final double gap;
  final double ratio; // width / height

  const GridSpec(this.cols, this.pad, this.gap, this.ratio);

  factory GridSpec.of(double w) {
    final cols = w < 600 ? 2 : w < 900 ? 3 : w < 1200 ? 4 : w < 1600 ? 5 : 6;
    final pad = w < 600 ? 16.0 : w < 900 ? 20.0 : 24.0;
    final gap = w < 600 ? 12.0 : 16.0;
    final cw = (w - pad * 2 - gap * (cols - 1)) / cols;
    // poster (3:4.2) + caption area
    final ch = cw * 1.38 + 52;
    return GridSpec(cols, pad, gap, cw / ch);
  }

  SliverGridDelegate get delegate => SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: gap,
        mainAxisSpacing: gap + 2,
        childAspectRatio: ratio,
      );
}

// ===========================================================================
// NETWORK IMAGE WITH SHIMMER + SAFE FALLBACK
// ===========================================================================

class NeoImage extends StatelessWidget {
  final String url;
  final IconData fallbackIcon;
  const NeoImage(this.url, {super.key, this.fallbackIcon = Icons.movie_outlined});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _ph();
    // disk + memory cache (thumbnails also show offline once seen); decoded at a sane size for smooth scrolling
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 120),
      memCacheWidth: 640,
      placeholder: (_, __) => const Shimmer(),
      errorWidget: (_, __, ___) => _ph(),
    );
  }

  Widget _ph() => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1B1F3A), Color(0xFF0D1020)],
          ),
        ),
        child: Icon(fallbackIcon, color: Neo.muted.withValues(alpha: 0.6), size: 34),
      );
}

class Shimmer extends StatefulWidget {
  const Shimmer({super.key});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-1.5 + 3 * _c.value, 0),
            end: Alignment(-0.5 + 3 * _c.value, 0),
            colors: [
              Neo.surface,
              Colors.white.withValues(alpha: 0.08),
              Neo.surface,
            ],
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ===========================================================================
// PRESSABLE 3D TILT
// ===========================================================================

class Tilt3D extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const Tilt3D({super.key, required this.child, required this.onTap});

  @override
  State<Tilt3D> createState() => _Tilt3DState();
}

class _Tilt3DState extends State<Tilt3D> {
  Offset _o = Offset.zero; // -1..1
  bool _down = false;
  bool _hover = false;

  void _upd(Offset local, Size s) {
    setState(() {
      _down = true;
      _o = Offset(
        ((local.dx / s.width) * 2 - 1).clamp(-1.0, 1.0).toDouble(),
        ((local.dy / s.height) * 2 - 1).clamp(-1.0, 1.0).toDouble(),
      );
    });
  }

  void _reset() => setState(() {
        _down = false;
        _o = Offset.zero;
      });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (d) => _upd(d.localPosition, size),
          onTapUp: (_) => _reset(),
          onTapCancel: _reset,
          child: TweenAnimationBuilder<Offset>(
            tween: Tween<Offset>(begin: Offset.zero, end: _o),
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            builder: (context, o, child) {
              final m = Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..rotateX(-o.dy * 0.14)
                ..rotateY(o.dx * 0.14);
              return Transform.scale(
                scale: _down ? 0.97 : (_hover ? 1.035 : 1.0),
                child: Transform(alignment: Alignment.center, transform: m, child: child),
              );
            },
            child: widget.child,
          ),
          ),
        );
      },
    );
  }
}

// ===========================================================================
// POSTER CARD
// ===========================================================================

class PosterCard extends StatelessWidget {
  final String title;
  final String thumb;
  final String badge;
  final Color badgeColor;
  final String? sub;
  final IconData icon;
  final VoidCallback onTap;
  final String? saveCollection;
  final String? saveId;
  final bool saved;
  final bool removeMode;

  const PosterCard({
    super.key,
    required this.title,
    required this.thumb,
    required this.badge,
    required this.onTap,
    this.badgeColor = Neo.cyan,
    this.sub,
    this.icon = Icons.play_arrow_rounded,
    this.saveCollection,
    this.saveId,
    this.saved = false,
    this.removeMode = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tilt3D(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: badgeColor.withValues(alpha: 0.35)),
                boxShadow: [
                  BoxShadow(
                    color: badgeColor.withValues(alpha: 0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(17),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NeoImage(thumb),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xCC080A14)],
                          stops: [0.55, 1],
                        ),
                      ),
                    ),
                    Positioned(top: 8, left: 8, child: NeoTag(badge, color: badgeColor)),
                    if (saveCollection != null && saveId != null)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: SaveMenuButton(collection: saveCollection!, docId: saveId!, saved: saved, removeMode: removeMode),
                      ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Neo.violet.withValues(alpha: 0.85),
                          boxShadow: [
                            BoxShadow(color: Neo.violet.withValues(alpha: 0.6), blurRadius: 12),
                          ],
                        ),
                        child: Icon(icon, size: 20, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Neo.text, fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          if (sub != null && sub!.isNotEmpty)
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Neo.muted, fontSize: 11.5),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// STAGGERED FADE-IN
// ===========================================================================

class FadeIn extends StatelessWidget {
  final int index;
  final Widget child;
  const FadeIn({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 380 + (index % 8) * 60),
      curve: Curves.easeOutCubic,
      builder: (_, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 18), child: c),
      ),
      child: child,
    );
  }
}

// ===========================================================================
// STATES + PAGE HEADER
// ===========================================================================

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? sub;
  const EmptyState({super.key, required this.icon, required this.text, this.sub});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: Neo.muted.withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Neo.text, fontSize: 16, fontWeight: FontWeight.w600)),
            if (sub != null) ...[
              const SizedBox(height: 6),
              Text(sub!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Neo.muted, fontSize: 12.5)),
            ],
          ],
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  final String text;
  final VoidCallback? onRetry;
  const ErrorState({super.key, required this.text, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: Neo.pink),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Neo.text, fontSize: 15, fontWeight: FontWeight.w600)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              SizedBox(width: 160, child: NeoButton(label: 'RETRY', onTap: onRetry)),
            ],
          ],
        ),
      ),
    );
  }
}

class PageHeader extends StatelessWidget {
  final String overline;
  final String title;
  final Widget? trailing;
  final double pad;
  const PageHeader({
    super.key,
    required this.overline,
    required this.title,
    this.trailing,
    this.pad = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 14, pad, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  overline.toUpperCase(),
                  style: const TextStyle(
                    color: Neo.cyan,
                    fontFamily: Neo.mono,
                    fontSize: 10.5,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Neo.text,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const GlassIconButton({super.key, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Neo.glass,
      shape: CircleBorder(side: BorderSide(color: Neo.line)),
      child: InkWell(
        customBorder: const CircleBorder(),
        hoverColor: Neo.cyan.withValues(alpha: 0.14),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Neo.text, size: 22),
        ),
      ),
    );
  }
}

/// Grid of skeleton cards while loading.
class SkeletonGrid extends StatelessWidget {
  final GridSpec spec;
  const SkeletonGrid({super.key, required this.spec});

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: spec.pad),
      sliver: SliverGrid(
        gridDelegate: spec.delegate,
        delegate: SliverChildBuilderDelegate(
          (_, __) => ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: const Shimmer(),
          ),
          childCount: spec.cols * 3,
        ),
      ),
    );
  }
}

class NeoSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  const NeoSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      cursorColor: Neo.cyan,
      textInputAction: TextInputAction.search,
      style: const TextStyle(color: Neo.text, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF50567A)),
        prefixIcon: const Icon(Icons.search_rounded, color: Neo.muted),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, v, __) => v.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  onPressed: controller.clear,
                  icon: const Icon(Icons.close_rounded, color: Neo.muted, size: 20),
                ),
        ),
        filled: true,
        fillColor: Neo.glass,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Neo.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Neo.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Neo.cyan, width: 1.4),
        ),
      ),
    );
  }
}
