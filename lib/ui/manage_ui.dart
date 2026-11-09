import 'package:flutter/material.dart';
import 'media.dart';
import 'neo.dart';

/// Phase 3 shared kit: scaffold, dialog shell, inputs, segmented control,
/// progress bar, list tile. Every Watch/Manage page reuses these.

// ---------------------------------------------------------------------------
// SCAFFOLD  (background + safe area + back header + max-width centering)
// ---------------------------------------------------------------------------

class NeoScaffold extends StatelessWidget {
  final String overline;
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? fab;
  final Widget? bottom;
  final double maxWidth;
  final bool plainBg;

  const NeoScaffold({
    super.key,
    required this.overline,
    required this.title,
    required this.body,
    this.actions = const [],
    this.fab,
    this.bottom,
    this.maxWidth = 980,
    this.plainBg = false,
  });

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    final content = SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Row(
                  children: [
                    if (canPop) ...[
                      GlassIconButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            overline.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Neo.cyan,
                              fontFamily: Neo.mono,
                              fontSize: 10.5,
                              letterSpacing: 2,
                            ),
                          ),
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Neo.text,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final a in actions) ...[const SizedBox(width: 8), a],
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Neo.bg,
      floatingActionButton: fab,
      bottomNavigationBar: bottom,
      body: plainBg ? content : NeoBackground(child: content),
    );
  }
}

// ---------------------------------------------------------------------------
// DIALOG SHELL  (drop-in replacement for AlertDialog)
// ---------------------------------------------------------------------------

class NeoDialog extends StatelessWidget {
  final String title;
  final String? sub;
  final IconData icon;
  final Color accent;
  final Widget content;
  final List<Widget> actions;

  const NeoDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.sub,
    this.icon = Icons.auto_awesome_rounded,
    this.accent = Neo.cyan,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Container(
          decoration: BoxDecoration(
            color: Neo.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: accent.withValues(alpha: 0.35)),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.18),
                blurRadius: 40,
                spreadRadius: -6,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.14),
                        border: Border.all(color: accent.withValues(alpha: 0.4)),
                      ),
                      child: Icon(icon, color: accent, size: 20),
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
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (sub != null)
                            Text(
                              sub!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Neo.muted,
                                fontFamily: Neo.mono,
                                fontSize: 10.5,
                                letterSpacing: 1,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: content,
                ),
              ),
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 10,
                    runSpacing: 8,
                    children: actions,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact dialog / sheet button.
class NeoSmallButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final Color? color;
  final bool loading;
  final IconData? icon;

  const NeoSmallButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.color,
    this.loading = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Neo.cyan;
    final enabled = onTap != null && !loading;
    return Opacity(
      opacity: onTap == null && !loading ? 0.5 : 1,
      child: Material(
        color: primary ? c : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: primary ? c : Neo.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 84),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                widthFactor: 1,
                child: loading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: primary ? Neo.bg : c,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, size: 17, color: primary ? Neo.bg : c),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            label,
                            style: TextStyle(
                              color: primary ? Neo.bg : (color ?? Neo.text),
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Simple confirm dialog. Returns true when confirmed.
Future<bool> neoConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'CONFIRM',
  bool danger = false,
  IconData icon = Icons.help_outline_rounded,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => NeoDialog(
      title: title,
      icon: danger ? Icons.warning_amber_rounded : icon,
      accent: danger ? Neo.pink : Neo.cyan,
      content: Text(
        message,
        style: const TextStyle(color: Neo.muted, fontSize: 14, height: 1.45),
      ),
      actions: [
        NeoSmallButton(label: 'CANCEL', onTap: () => Navigator.pop(ctx, false)),
        NeoSmallButton(
          label: confirmLabel,
          primary: true,
          color: danger ? Neo.pink : Neo.cyan,
          onTap: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Styled bottom sheet.
Future<T?> showNeoSheet<T>(
  BuildContext context, {
  required String title,
  String? sub,
  required Widget child,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          decoration: BoxDecoration(
            color: Neo.surface,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Neo.cyan.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Neo.line,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: SectionHeader(title: title, tag: sub),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// INPUT  (TextFormField based -> supports Form validators)
// ---------------------------------------------------------------------------

class NeoInput extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData? icon;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? action;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final Widget? suffix;

  const NeoInput({
    super.key,
    required this.controller,
    required this.label,
    this.hint = '',
    this.icon,
    this.maxLines = 1,
    this.keyboardType,
    this.action,
    this.validator,
    this.onChanged,
    this.enabled = true,
    this.suffix,
  });

  OutlineInputBorder _b(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c, width: w),
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty) ...[
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Neo.muted,
              fontFamily: Neo.mono,
              fontSize: 10.5,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 7),
        ],
        TextFormField(
          controller: controller,
          enabled: enabled,
          maxLines: maxLines,
          minLines: 1,
          keyboardType: keyboardType,
          textInputAction: action,
          validator: validator,
          onChanged: onChanged,
          cursorColor: Neo.cyan,
          style: const TextStyle(color: Neo.text, fontSize: 15),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF50567A)),
            prefixIcon:
                icon == null ? null : Icon(icon, color: Neo.muted, size: 20),
            suffixIcon: suffix,
            isDense: true,
            filled: true,
            fillColor: Colors.black.withValues(alpha: 0.28),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            enabledBorder: _b(Neo.line),
            disabledBorder: _b(Neo.line),
            focusedBorder: _b(Neo.cyan, 1.4),
            errorBorder: _b(Neo.pink),
            focusedErrorBorder: _b(Neo.pink, 1.4),
            errorStyle: const TextStyle(color: Neo.pink, fontSize: 11.5),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// SEGMENTED CONTROL
// ---------------------------------------------------------------------------

class NeoOpt<T> {
  final T value;
  final String label;
  final IconData icon;
  const NeoOpt(this.value, this.label, this.icon);
}

class NeoSegmented<T> extends StatelessWidget {
  final List<NeoOpt<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  const NeoSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Neo.line),
      ),
      child: Row(
        children: [
          for (final o in options)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(o.value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: o.value == selected
                        ? const LinearGradient(colors: [Neo.cyan, Neo.violet])
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        o.icon,
                        size: 17,
                        color: o.value == selected ? Neo.bg : Neo.muted,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          o.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: o.value == selected ? Neo.bg : Neo.muted,
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PROGRESS BAR  (determinate; value null => indeterminate)
// ---------------------------------------------------------------------------

class NeoProgress extends StatelessWidget {
  final double? value;
  final String label;
  const NeoProgress({super.key, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final pct = value == null ? '' : '${(value! * 100).clamp(0, 100).toStringAsFixed(0)}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Neo.muted,
                  fontFamily: Neo.mono,
                  fontSize: 11,
                  letterSpacing: 1,
                ),
              ),
            ),
            Text(
              pct,
              style: const TextStyle(
                color: Neo.cyan,
                fontFamily: Neo.mono,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 8,
            color: Neo.cyan,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// ACTION TILE  (icon + title + subtitle + chevron, with 3D tilt)
// ---------------------------------------------------------------------------

class NeoActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final String? tag;

  const NeoActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.color = Neo.cyan,
    this.tag,
  });

  @override
  Widget build(BuildContext context) {
    return Tilt3D(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: Neo.surface,
          border: Border.all(color: color.withValues(alpha: 0.28)),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.08)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tag != null) ...[
                    NeoTag(tag!, color: color),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Neo.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Neo.muted, fontSize: 12.5, height: 1.35),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: color, size: 26),
          ],
        ),
      ),
    );
  }
}

/// Floating snack helper (same look everywhere).
void neoSnack(BuildContext context, String msg, {bool error = false}) {
  if (!context.mounted) return;
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
            color: error ? Neo.pink : Neo.cyan,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, maxLines: 3, overflow: TextOverflow.ellipsis)),
        ],
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: (error ? Neo.pink : Neo.cyan).withValues(alpha: 0.45)),
      ),
    ),
  );
}
