import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'neo.dart';

/// Desktop layer: breakpoints, mouse scrolling + visible scrollbars,
/// hover effect and the left side navigation used on wide windows.

class Bp {
  static const double desktop = 900; // side nav + wide layout from here
  static const double wide = 1400;
  static bool isDesktop(double w) => w >= desktop;

  /// Max width for content pages so lines/cards never stretch on big monitors.
  static double content(double w) => w >= wide ? 1280 : w;
}

/// Mouse drag + trackpad scroll, always-visible thin scrollbar on desktop.
class DesktopScrollBehavior extends MaterialScrollBehavior {
  const DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails d) {
    if (d.direction == AxisDirection.left || d.direction == AxisDirection.right) {
      return child; // no scrollbar on horizontal rails
    }
    final w = MediaQuery.sizeOf(context).width;
    if (!Bp.isDesktop(w)) return child;
    return Scrollbar(controller: d.controller, child: child);
  }
}

/// Wraps any tappable card: lifts slightly + shows glow on mouse hover.
class HoverLift extends StatefulWidget {
  final Widget child;
  final double scale;
  const HoverLift({super.key, required this.child, this.scale = 1.03});

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: AnimatedScale(
        scale: _h ? widget.scale : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: _h
                ? [BoxShadow(color: Neo.cyan.withValues(alpha: 0.22), blurRadius: 22)]
                : const [],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Left navigation for desktop windows. Collapses to icons under 1100px.
class DesktopSideNav extends StatelessWidget {
  final int index;
  final List<int> tabs;
  final ValueChanged<int> onChanged;
  final List<(IconData, IconData, String)> items;

  const DesktopSideNav({
    super.key,
    required this.index,
    required this.tabs,
    required this.onChanged,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final expanded = MediaQuery.sizeOf(context).width >= 1100;
    return Container(
      width: expanded ? 224 : 76,
      decoration: BoxDecoration(
        color: Neo.bg2,
        border: Border(right: BorderSide(color: Neo.line)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(expanded ? 20 : 0, 22, expanded ? 12 : 0, 22),
              child: expanded
                  ? const Text(
                      Neo.appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Neo.cyan,
                        fontFamily: Neo.mono,
                        fontSize: 13,
                        letterSpacing: 2.5,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : const Icon(Icons.play_circle_fill_rounded, color: Neo.cyan, size: 30),
            ),
            for (final i in tabs)
              _NavItem(
                icon: index == i ? items[i].$2 : items[i].$1,
                label: items[i].$3,
                selected: index == i,
                expanded: expanded,
                onTap: () => onChanged(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected, expanded;
  final VoidCallback onTap;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final col = sel ? Neo.cyan : (_h ? Neo.text : Neo.muted);
    final item = MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Material(
          color: sel
              ? Neo.cyan.withValues(alpha: 0.14)
              : (_h ? Colors.white.withValues(alpha: 0.05) : Colors.transparent),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: widget.onTap,
            child: SizedBox(
              height: 48,
              child: Row(
                mainAxisAlignment:
                    widget.expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
                  if (widget.expanded) const SizedBox(width: 14),
                  Icon(widget.icon, size: 23, color: col),
                  if (widget.expanded) ...[
                    const SizedBox(width: 14),
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: col,
                        fontSize: 14.5,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return widget.expanded ? item : Tooltip(message: widget.label, child: item);
  }
}

/// Centers a page body and caps its width on big monitors.
class CenterMax extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const CenterMax({super.key, required this.child, this.maxWidth = 920});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}
