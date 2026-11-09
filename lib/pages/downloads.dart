import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/download_models.dart';
import '../services/platform_flags.dart';
import '../services/download_service.dart';
import '../services/session_service.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/desktop.dart';
import '../ui/neo.dart';
import 'offline_player.dart';

/// Downloads tab: "Current Downloads" (live progress + Pause/Resume/Cancel) and
/// "Downloaded" (play offline from local storage). Works without internet.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DownloadService.syncWithDisk();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) DownloadService.syncWithDisk(); // files may have been removed meanwhile
  }

  void _toast(String m) {
    if (!mounted || m.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _do(Future<DlResult> f) async {
    final r = await f;
    if (!r.ok) _toast(r.message);
  }

  Future<bool> _confirm(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: Neo.surface,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
          ],
        ),
      ) ??
      false;

  Future<void> _play(DownloadRecord r) async {
    final path = await DownloadService.localPath(r);
    if (!mounted) return;
    if (path == null) {
      _toast('This file is no longer on the device.');
      DownloadService.syncWithDisk();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OfflinePlayerPage(path: path, title: r.title)));
  }

  Widget _tab(IconData icon, String label, int n) => Tab(
        height: 42,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text('$label ($n)', overflow: TextOverflow.ellipsis)),
          ],
        ),
      );

  Widget _list(List<Widget> children) => CenterMax(
        child: ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.only(top: 14, bottom: 24),
          children: children,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, DownloadRecord>>(
      valueListenable: DownloadService.records,
      builder: (_, __, ___) {
        final all = DownloadService.forCurrentUser();
        final current = all.where((r) => !r.isDone).toList();
        final done = all.where((r) => r.isDone).toList();
        return Column(
          children: [
            const PageHeader(overline: 'Library // Offline', title: 'Downloads'),
            ValueListenableBuilder<bool>(
              valueListenable: SessionService.allowDownloads,
              builder: (_, __, ___) => DownloadService.canDownload
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: _notice('Downloads are disabled by the administrator. Your downloaded videos still play offline.'),
                    ),
            ),
            _locationCard(),
            // Same pill tab design as Manage Videos (Videos | Playlists).
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Neo.line),
              ),
              child: TabBar(
                controller: _tabs,
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(colors: [Neo.cyan, Neo.violet]),
                ),
                labelColor: Neo.bg,
                unselectedLabelColor: Neo.muted,
                labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 0.6),
                splashBorderRadius: BorderRadius.circular(14),
                tabs: [
                  _tab(Icons.downloading_rounded, 'Current', current.length),
                  _tab(Icons.download_done_rounded, 'Downloaded', done.length),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _list([
                    if (current.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: EmptyState(
                            icon: Icons.downloading_rounded,
                            text: 'No active downloads',
                            sub: 'Use the Download button below any video.'),
                      )
                    else
                      for (final r in current) _currentCard(r),
                  ]),
                  _list([
                    if (done.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: EmptyState(
                            icon: Icons.download_done_rounded,
                            text: 'Nothing downloaded yet',
                            sub: 'Finished downloads appear here and play without internet.'),
                      )
                    else
                      for (final r in done) _doneCard(r),
                  ]),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- download location
  Widget _locationCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: ValueListenableBuilder<String>(
          valueListenable: DownloadService.location,
          builder: (_, __, ___) => FutureBuilder<String>(
            future: DownloadService.currentFolder(),
            builder: (_, snap) => Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Neo.line),
              ),
              child: Row(children: [
                const Icon(Icons.folder_rounded, color: Neo.cyan, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('DOWNLOAD LOCATION',
                        style: TextStyle(color: Neo.muted, fontFamily: Neo.mono, fontSize: 10, letterSpacing: 1.6)),
                    const SizedBox(height: 3),
                    Text(
                      snap.data ?? '…',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Neo.text, fontSize: 12.5),
                    ),
                  ]),
                ),
                if (Platform.isAndroid || isWindows)
                  TextButton(
                    onPressed: _changeLocation,
                    child: const Text('CHANGE', style: TextStyle(color: Neo.cyan, fontWeight: FontWeight.w800)),
                  ),
              ]),
            ),
          ),
        ),
      );

  Future<void> _changeLocation() async {
    final msg = await showNeoSheet<String>(
      context,
      title: 'Download location',
      sub: 'for new downloads',
      child: const _LocationSheet(),
    );
    if (msg != null && mounted) neoSnack(context, msg, error: msg.startsWith("This folder"));
  }

  Widget _notice(String t) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Neo.amber.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Neo.amber.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline_rounded, color: Neo.amber, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(t, style: const TextStyle(color: Neo.text, fontSize: 12.5))),
        ]),
      );

  Widget _thumb(DownloadRecord r, {bool play = false}) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 104,
          height: 62,
          child: Stack(fit: StackFit.expand, children: [
            NeoImage(r.thumbnail),
            if (play)
              const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white70, size: 30)),
          ]),
        ),
      );

  Widget _shell(Widget child, {VoidCallback? onTap, Color? border}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Material(
          color: Neo.glass,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border ?? Neo.line),
              ),
              child: child,
            ),
          ),
        ),
      );

  Widget _titleBlock(DownloadRecord r) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Neo.text, fontWeight: FontWeight.w700, fontSize: 14, height: 1.2)),
        if (r.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(r.subtitle, style: const TextStyle(color: Neo.muted, fontSize: 11.5)),
          ),
      ]);

  Widget _currentCard(DownloadRecord r) {
    final paused = r.state == DlState.paused;
    final failed = r.state == DlState.failed;
    final color = failed ? Neo.pink : (paused ? Neo.amber : Neo.cyan);
    final pct = (r.progress * 100).clamp(0, 100).toStringAsFixed(0);
    final size = r.total > 0 ? '${fmtBytes(r.bytes)} / ${fmtBytes(r.total)}' : fmtBytes(r.bytes);
    final status = failed
        ? 'Failed'
        : paused
            ? 'Paused'
            : r.state == DlState.queued
                ? 'Waiting…'
                : 'Downloading';
    return _shell(
      border: color.withValues(alpha: 0.30),
      Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _thumb(r),
          const SizedBox(width: 10),
          Expanded(child: _titleBlock(r)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: r.state == DlState.queued && r.progress == 0 ? null : r.progress,
            minHeight: 6,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            color: color,
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(
              '$status · $pct% · $size${r.speedMBps > 0 && r.state == DlState.running ? ' · ${r.speedMBps.toStringAsFixed(1)} MB/s' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w600),
            ),
          ),
          if (failed)
            _act(Icons.refresh_rounded, 'Retry', Neo.cyan, () => _do(DownloadService.resume(r.id)))
          else if (paused)
            _act(Icons.play_arrow_rounded, 'Resume', Neo.cyan, () => _do(DownloadService.resume(r.id)))
          else
            _act(Icons.pause_rounded, 'Pause', Neo.text, () => _do(DownloadService.pause(r.id))),
          _act(Icons.close_rounded, 'Cancel', Neo.pink, () async {
            if (await _confirm('Cancel download?', 'The partly downloaded file will be deleted.', 'Cancel download')) {
              await DownloadService.cancel(r.id);
            }
          }),
        ]),
        if ((failed || paused) && r.error.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(r.error, style: const TextStyle(color: Neo.muted, fontSize: 11.5)),
            ),
          ),
      ]),
    );
  }

  Widget _act(IconData i, String tip, Color c, VoidCallback onTap) => IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
        onPressed: onTap,
        icon: Icon(i, color: c, size: 22),
      );

  Widget _doneCard(DownloadRecord r) => _shell(
        onTap: () => _play(r),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _thumb(r, play: true),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _titleBlock(r),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                _chip(fmtBytes(r.bytes), Neo.muted),
                _chip('OFFLINE', Neo.cyan),
                if (r.gallery) _chip('IN GALLERY', Neo.violet),
              ]),
            ]),
          ),
          PopupMenuButton<String>(
            color: Neo.surface,
            icon: const Icon(Icons.more_vert_rounded, color: Neo.muted),
            onSelected: (v) async {
              if (v == 'gallery') {
                _toast((await DownloadService.saveToGallery(r.id)).message);
              } else if (v == 'delete') {
                if (await _confirm('Delete download?', 'The offline copy will be removed from this app. A copy already saved in your Gallery is not deleted.', 'Delete')) {
                  await DownloadService.delete(r.id);
                }
              }
            },
            itemBuilder: (_) => [
              if (!r.gallery) const PopupMenuItem(value: 'gallery', child: Text('Save to Gallery')),
              const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Neo.pink))),
            ],
          ),
        ]),
      );

  Widget _chip(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(t, style: TextStyle(color: c, fontSize: 10, fontFamily: Neo.mono, letterSpacing: 0.5)),
      );
}


/// Bottom sheet: pick where NEW downloads are saved.
class _LocationSheet extends StatefulWidget {
  const _LocationSheet();

  @override
  State<_LocationSheet> createState() => _LocationSheetState();
}

class _LocationSheetState extends State<_LocationSheet> {
  final _path = TextEditingController();
  bool _busy = false;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _path.text = DownloadService.location.value;
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _apply(String path) async {
    setState(() {
      _busy = true;
      _err = '';
    });
    final r = await DownloadService.setLocation(path);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, path.isEmpty ? 'Downloads will use app storage.' : 'New downloads will be saved in $path');
    } else {
      setState(() {
        _busy = false;
        _err = r.message;
      });
    }
  }

  Widget _option(IconData icon, String title, String sub, String path) {
    final selected = DownloadService.location.value == path;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: !_busy,
      leading: Icon(icon, color: selected ? Neo.cyan : Neo.muted),
      title: Text(title, style: const TextStyle(color: Neo.text, fontWeight: FontWeight.w700)),
      subtitle: Text(sub, style: const TextStyle(color: Neo.muted, fontSize: 11.5)),
      trailing: selected ? const Icon(Icons.check_circle_rounded, color: Neo.cyan) : null,
      onTap: () => _apply(path),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _option(Icons.lock_rounded, 'App storage (default)', 'Private to this app, not visible in file manager', ''),
          for (final e in DownloadService.presetFolders.entries)
            _option(Icons.folder_open_rounded, e.key, e.value, e.value),
          const SizedBox(height: 8),
          NeoInput(
            controller: _path,
            label: 'Custom folder path',
            hint: isWindows ? r'C:\Users\you\Videos\My Anime' : '/storage/emulated/0/Movies/My Anime',
            icon: Icons.edit_location_alt_rounded,
          ),
          if (_err.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_err, style: const TextStyle(color: Neo.pink, fontSize: 12.5)),
          ],
          const SizedBox(height: 14),
          NeoButton(
            label: 'USE THIS FOLDER',
            icon: Icons.check_rounded,
            loading: _busy,
            onTap: _busy ? null : () => _apply(_path.text),
          ),
          const SizedBox(height: 10),
          const Text(
            'Only new downloads use this folder. Videos you already downloaded stay where they are.',
            style: TextStyle(color: Neo.muted, fontSize: 11.5),
          ),
        ]),
      ),
    );
  }
}
