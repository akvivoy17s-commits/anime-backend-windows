import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

/// NEO//UI design tokens + shared widgets (Phase 1 foundation).
class Neo {
  static const String appName = 'ANIME PORTAL';

  static const Color bg = Color(0xFF080A14);
  static const Color bg2 = Color(0xFF0D1020);
  static const Color surface = Color(0xFF12162A);
  static const Color cyan = Color(0xFF4DD8F0);
  static const Color violet = Color(0xFFA78BFA);
  static const Color pink = Color(0xFFFB7185);
  static const Color amber = Color(0xFFFBBF24);
  static const Color text = Color(0xFFE8EAF6);
  static const Color muted = Color(0xFF8A90B0);
  static const String mono = 'monospace';

  static Color get line => Colors.white.withValues(alpha: 0.10);
  static Color get glass => Colors.white.withValues(alpha: 0.045);

  static ThemeData theme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: cyan,
        secondary: violet,
        surface: surface,
        error: pink,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surface,
        contentTextStyle: const TextStyle(color: text),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: cyan.withValues(alpha: 0.4)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bg2,
        indicatorColor: cyan.withValues(alpha: 0.18),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: cyan),
      visualDensity: VisualDensity.standard,
      // bottom sheets become a centered panel on wide windows instead of full width
      bottomSheetTheme: const BottomSheetThemeData(
        constraints: BoxConstraints(maxWidth: 640),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(8),
        radius: const Radius.circular(8),
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered)
            ? cyan.withValues(alpha: 0.65)
            : Colors.white.withValues(alpha: 0.22)),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: line),
        ),
        textStyle: const TextStyle(color: text, fontSize: 12),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// BACKGROUND: gradient + drifting glow orbs + faint grid
// ---------------------------------------------------------------------------

class NeoBackground extends StatefulWidget {
  final Widget child;
  const NeoBackground({super.key, required this.child});

  @override
  State<NeoBackground> createState() => _NeoBackgroundState();
}

class _NeoBackgroundState extends State<NeoBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => CustomPaint(painter: _BgPainter(_c.value)),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _BgPainter extends CustomPainter {
  final double v;
  _BgPainter(this.v);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Neo.bg, Neo.bg2, Neo.bg],
        ).createShader(rect),
    );

    final a = v * 2 * math.pi;
    _orb(canvas, size, Offset(size.width * (0.15 + 0.08 * math.sin(a)), size.height * 0.12),
        size.width * 0.7, Neo.violet, 0.20);
    _orb(canvas, size, Offset(size.width * (0.9 - 0.08 * math.cos(a)), size.height * 0.85),
        size.width * 0.8, Neo.cyan, 0.14);

    final g = Paint()
      ..color = Colors.white.withValues(alpha: 0.025)
      ..strokeWidth = 1;
    const step = 36.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), g);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
  }

  void _orb(Canvas c, Size s, Offset o, double r, Color col, double alpha) {
    c.drawCircle(
      o,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [col.withValues(alpha: alpha), col.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: o, radius: r)),
    );
  }

  @override
  bool shouldRepaint(covariant _BgPainter old) => old.v != v;
}

// ---------------------------------------------------------------------------
// GLASS CARD
// ---------------------------------------------------------------------------

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 22,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: Neo.glass,
            border: Border.all(color: borderColor ?? Neo.line),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// BUTTONS
// ---------------------------------------------------------------------------

class NeoButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool loading;

  const NeoButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    return Opacity(
      opacity: enabled || loading ? 1 : 0.55,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(colors: [Neo.cyan, Neo.violet]),
          boxShadow: [
            BoxShadow(
              color: Neo.cyan.withValues(alpha: 0.35),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? onTap : null,
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Neo.bg,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 20, color: Neo.bg),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          label,
                          style: const TextStyle(
                            color: Neo.bg,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class NeoGhostButton extends StatelessWidget {
  final String label;
  final Widget leading;
  final VoidCallback? onTap;

  const NeoGhostButton({
    super.key,
    required this.label,
    required this.leading,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.55 : 1,
      child: Material(
        color: Neo.glass,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Neo.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                leading,
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Neo.text,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
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

// ---------------------------------------------------------------------------
// TEXT FIELD
// ---------------------------------------------------------------------------

class NeoField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscure;
  final VoidCallback? onToggleObscure;
  final TextInputType? keyboardType;
  final TextInputAction? action;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofill;

  const NeoField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.onToggleObscure,
    this.keyboardType,
    this.action,
    this.onSubmitted,
    this.autofill,
  });

  OutlineInputBorder _border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c, width: w),
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Neo.muted,
            fontFamily: Neo.mono,
            fontSize: 11,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          textInputAction: action,
          onSubmitted: onSubmitted,
          autofillHints: autofill,
          cursorColor: Neo.cyan,
          style: const TextStyle(color: Neo.text, fontSize: 15),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF50567A)),
            prefixIcon: Icon(icon, color: Neo.muted, size: 20),
            suffixIcon: onToggleObscure == null
                ? null
                : IconButton(
                    onPressed: onToggleObscure,
                    icon: Icon(
                      obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: Neo.muted,
                      size: 20,
                    ),
                  ),
            filled: true,
            fillColor: Colors.black.withValues(alpha: 0.28),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            enabledBorder: _border(Neo.line),
            focusedBorder: _border(Neo.cyan, 1.4),
            border: _border(Neo.line),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// SECTION HEADER + TAG
// ---------------------------------------------------------------------------

class SectionHeader extends StatelessWidget {
  final String title;
  final String? tag;
  final Color color;

  const SectionHeader({
    super.key,
    required this.title,
    this.tag,
    this.color = Neo.violet,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 5,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Neo.text,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (tag != null)
          Text(
            tag!.toUpperCase(),
            style: const TextStyle(
              color: Neo.muted,
              fontFamily: Neo.mono,
              fontSize: 10,
              letterSpacing: 1.4,
            ),
          ),
      ],
    );
  }
}

class NeoTag extends StatelessWidget {
  final String text;
  final Color color;

  const NeoTag(this.text, {super.key, this.color = Neo.cyan});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontFamily: Neo.mono,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
