import 'dart:async';

import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../services/drive_agent_service.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/neo.dart';

/// Admin-only page: paste a Google Drive folder URL and let the agent add every video.
class DriveAgentPage extends StatefulWidget {
  const DriveAgentPage({super.key});

  @override
  State<DriveAgentPage> createState() => _DriveAgentPageState();
}

class _DriveAgentPageState extends State<DriveAgentPage> {
  final _url = TextEditingController();
  final _limit = TextEditingController();
  String _category = 'series';
  bool _retry = false;
  bool _busy = false; // a request is in flight
  Map<String, dynamic>? _plan;
  String _planKey = ''; // url|category the preview was made for
  final Map<String, Map<String, dynamic>> _edits = {}; // file_id -> changed fields
  int _shown = 40;
  final Set<String> _sel = {}; // file_ids selected for bulk edit
  bool _selMode = false; // checkboxes visible
  Map<String, dynamic> _st = {};
  Timer? _timer;

  bool get _running => _st['running'] == true;
  bool get _selecting => _selMode || _sel.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (AdminService.isAdmin) _refresh(silent: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _url.dispose();
    _limit.dispose();
    super.dispose();
  }

  void _msg(String m, {bool error = false}) {
    if (mounted) neoSnack(context, m, error: error);
  }

  void _syncTimer() {
    if (_running && _timer == null) {
      _timer = Timer.periodic(
          const Duration(seconds: 2), (_) => _refresh(silent: true));
    } else if (!_running && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    try {
      final s = await DriveAgentService.status();
      if (!mounted) return;
      setState(() => _st = s);
      _syncTimer();
    } on DriveAgentException catch (e) {
      if (!silent) _msg(e.message, error: true);
    }
  }

  /// Accepts: drive.google.com folder links (/folders/ID, ?id=ID, /drive/u/0/folders/ID),
  /// share.google / drive.app.goo.gl short links (resolved by the backend), or a bare folder ID.
  bool _validUrl() {
    final u = _url.text.trim();
    final host = (Uri.tryParse(u)?.host ?? '').toLowerCase();
    final isDrive = (host == 'drive.google.com' || host == 'docs.google.com') &&
        (u.contains('/folders/') || u.contains('id='));
    final isShort = host == 'share.google' ||
        host == 'drive.app.goo.gl' ||
        host == 'goo.gl';
    final isBareId = RegExp(r'^[\w-]{20,}$').hasMatch(u);
    final ok = isDrive || isShort || isBareId;
    if (!ok) {
      _msg(
          u.contains('/file/d/')
              ? 'That is a FILE link. Paste the FOLDER link.'
              : 'Paste a Google Drive FOLDER link.',
          error: true);
    }
    return ok;
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } on DriveAgentException catch (e) {
      _msg(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    if (!_validUrl()) return;
    await _run(() async {
      final p = await DriveAgentService.plan(_url.text.trim(), _category);
      if (!mounted) return;
      final key = '${_url.text.trim()}|$_category';
      setState(() {
        if (key != _planKey) _edits.clear(); // edits belong to one folder/category
        _planKey = key;
        _plan = p;
        _shown = 40;
        _sel.clear();
        _selMode = false;
      });
    });
  }

  Map<String, dynamic> _merged(Map it) =>
      Map<String, dynamic>.from(it)..addAll(_edits['${it['file_id']}'] ?? const {});

  Future<void> _edit(Map it) async {
    final id = '${it['file_id']}';
    final r = await showNeoSheet<Map<String, dynamic>>(
      context,
      title: 'Edit video',
      sub: 'before upload',
      child: _EditForm(item: _merged(it), series: _category == 'series'),
    );
    if (r == null || !mounted) return;
    final diff = <String, dynamic>{
      for (final e in r.entries)
        if ('${e.value}' != '${it[e.key] ?? ''}') e.key: e.value,
    };
    setState(() => diff.isEmpty ? _edits.remove(id) : _edits[id] = diff);
  }

  // ------------------------------------------------------------ bulk edit
  List<Map> get _planItems =>
      ((_plan?['items'] as List?) ?? const []).cast<Map>();

  bool _canEdit(Map it) => '${it['status']}' != 'done';

  void _toggle(String id) => setState(() {
        if (!_sel.remove(id)) _sel.add(id);
      });

  Future<void> _bulkEdit() async {
    final targets =
        _planItems.where((it) => _sel.contains('${it['file_id']}')).toList();
    if (targets.isEmpty) return;
    final r = await showNeoSheet<Map<String, String>>(
      context,
      title: 'Edit ${targets.length} videos',
      sub: 'same change for all',
      child: _BulkEditForm(series: _category == 'series'),
    );
    if (r == null || !mounted) return;
    final find = r['find'] ?? '';
    final sameTitle = r['title'] ?? '';
    var hit = 0; // titles actually changed by find/replace
    setState(() {
      for (final it in targets) {
        final id = '${it['file_id']}';
        final m = _merged(it);
        var title = '${m['title']}';
        if (find.isNotEmpty) {
          final t = title.replaceAll(find, r['replace'] ?? '').trim();
          if (t.isNotEmpty && t != title) {
            title = t; // never blank a title
            hit++;
          }
        }
        if (sameTitle.isNotEmpty) title = sameTitle;
        final next = <String, dynamic>{'title': title};
        for (final k in const ['season', 'episode']) {
          if ((r[k] ?? '').isNotEmpty) next[k] = int.parse(r[k]!);
        }
        for (final k in const [
          'series_name', 'video_url', 'thumbnail_url', 'description'
        ]) {
          if ((r[k] ?? '').isNotEmpty) next[k] = r[k];
        }
        final diff = Map<String, dynamic>.from(_edits[id] ?? const {});
        for (final e in next.entries) {
          if ('${e.value}' != '${it[e.key] ?? ''}') {
            diff[e.key] = e.value;
          } else {
            diff.remove(e.key);
          }
        }
        diff.isEmpty ? _edits.remove(id) : _edits[id] = diff;
      }
      _sel.clear();
      _selMode = false;
    });
    if (find.isNotEmpty && hit == 0 && sameTitle.isEmpty) {
      _msg('"$find" was not found in the selected titles. Copy the text exactly as shown in the list.',
          error: true);
    } else {
      _msg('Edited ${targets.length} video(s)'
          '${find.isNotEmpty ? ' (title changed in $hit)' : ''}. '
          'Press START AGENT to save them to Firebase.');
    }
  }

  Widget _check(bool on) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          gradient: on
              ? const LinearGradient(colors: [Neo.cyan, Neo.violet])
              : null,
          border: Border.all(color: on ? Neo.cyan : Neo.line, width: 1.4),
        ),
        child: on
            ? const Icon(Icons.check_rounded, size: 16, color: Neo.bg)
            : null,
      );

  Widget _selectionBar() {
    final ids = _planItems.where(_canEdit).map((e) => '${e['file_id']}').toSet();
    final all = ids.isNotEmpty && ids.every(_sel.contains);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                setState(() => all ? _sel.removeAll(ids) : _sel.addAll(ids)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _check(all),
              const SizedBox(width: 6),
              _txt('All', s: 12),
            ]),
          ),
          NeoTag('${_sel.length} SELECTED', color: Neo.cyan),
          NeoSmallButton(
              label: 'CANCEL',
              onTap: () => setState(() {
                    _sel.clear();
                    _selMode = false;
                  })),
          NeoSmallButton(
              label: 'EDIT',
              icon: Icons.edit_rounded,
              primary: true,
              onTap: _sel.isEmpty ? null : _bulkEdit),
        ],
      ),
    );
  }

  Future<void> _start() async {
    if (!_validUrl()) return;
    final limitText = _limit.text.trim();
    final limit = limitText.isEmpty ? null : int.tryParse(limitText);
    if (limitText.isNotEmpty && (limit == null || limit < 1)) {
      _msg('Limit must be a positive number.', error: true);
      return;
    }
    setState(() {
      _sel.clear();
      _selMode = false;
    });
    await _run(() async {
      final same = _planKey == '${_url.text.trim()}|$_category';
      await DriveAgentService.start(_url.text.trim(), _category,
          retryFailed: _retry, limit: limit, edits: same ? _edits : const {});
      await _refresh();
      _msg('Agent started');
    });
  }

  Future<void> _stop() => _run(() async {
        await DriveAgentService.stop();
        _msg('Stopping after the current video...');
      });

  Future<void> _retryFailed() => _run(() async {
        final n = await DriveAgentService.retryFailed();
        _msg('$n failed video(s) reset. Press Start to retry.');
        await _refresh();
      });

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AdminService.notifier,
        builder: (c, _, __) => _page(c),
      );

  Widget _card(List<Widget> children) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Neo.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _txt(String t, {Color c = Neo.text, double s = 13, bool mono = false}) =>
      Text(t,
          style: TextStyle(
              color: c, fontSize: s, fontFamily: mono ? Neo.mono : null));

  Widget _page(BuildContext context) {
    if (!AdminService.isAdmin) {
      return const NeoScaffold(
        overline: 'Access // Restricted',
        title: 'Drive Agent',
        body: EmptyState(
          icon: Icons.lock_outline_rounded,
          text: 'Admin access only',
          sub: 'Sign in with the admin account to use the Drive agent.',
        ),
      );
    }
    final busy = _busy;
    return NeoScaffold(
      overline: 'Admin // Automation',
      title: 'Drive Agent',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
        children: [
          const SectionHeader(title: 'Source', tag: 'google drive'),
          const SizedBox(height: 12),
          NeoInput(
            controller: _url,
            label: 'Drive folder URL',
            hint: 'https://drive.google.com/drive/folders/...',
            icon: Icons.folder_shared_rounded,
            enabled: !_running && !busy,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          NeoSegmented<String>(
            selected: _category,
            onChanged: (v) {
              if (!_running) setState(() => _category = v);
            },
            options: const [
              NeoOpt('series', 'Series', Icons.tv_rounded),
              NeoOpt('movies', 'Movies', Icons.movie_rounded),
            ],
          ),
          const SizedBox(height: 12),
          NeoInput(
            controller: _limit,
            label: 'Limit (optional)',
            hint: 'e.g. 3 to test with the first 3 videos',
            icon: Icons.numbers_rounded,
            enabled: !_running && !busy,
            keyboardType: TextInputType.number,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: Neo.cyan,
            title: _txt('Also retry previously errored videos'),
            value: _retry,
            onChanged: _running ? null : (v) => setState(() => _retry = v),
          ),
          const SizedBox(height: 6),
          NeoButton(
            label: 'PREVIEW (no upload)',
            icon: Icons.visibility_rounded,
            loading: busy && !_running,
            onTap: (_running || busy) ? null : _preview,
          ),
          const SizedBox(height: 12),
          if (_running)
            NeoButton(
              label: 'STOP',
              icon: Icons.stop_circle_rounded,
              loading: busy,
              onTap: busy ? null : _stop,
            )
          else
            NeoButton(
              label: 'START AGENT',
              icon: Icons.play_arrow_rounded,
              loading: busy,
              onTap: busy ? null : _start,
            ),
          if (_plan != null && !_running) ...[
            const SizedBox(height: 22),
            _previewCard(),
          ],
          if (_st['state'] != null && _st['state'] != 'idle') ...[
            const SizedBox(height: 22),
            _statusCard(),
          ],
        ],
      ),
    );
  }

  Widget _previewCard() {
    final items = ((_plan!['items'] as List?) ?? const []).cast<Map>();
    return _card([
      _txt('${_plan!['total']} video(s) found, ${_plan!['new']} new',
          c: Neo.cyan, s: 14),
      const SizedBox(height: 2),
      _txt('Tap a video to edit it, or use SELECT MULTIPLE to change many at once.',
          c: Neo.muted, s: 11.5),
      const SizedBox(height: 8),
      if (_edits.isNotEmpty) ...[
        _txt('${_edits.length} video(s) edited. Saved to Firebase only after START AGENT.',
            c: Neo.amber, s: 11.5),
        const SizedBox(height: 8),
      ],
      if (_selecting)
        _selectionBar()
      else
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Align(
            alignment: Alignment.centerRight,
            child: NeoSmallButton(
              label: 'SELECT MULTIPLE',
              icon: Icons.checklist_rounded,
              onTap: () => setState(() => _selMode = true),
            ),
          ),
        ),
      for (final it in items.take(_shown)) _itemRow(it),
      if (items.length > _shown)
        TextButton(
          onPressed: () => setState(() => _shown += 40),
          child: _txt('Show more (${items.length - _shown} left)', c: Neo.cyan, s: 12),
        ),
    ]);
  }

  Widget _itemRow(Map it) {
    final m = _merged(it);
    final status = '${it['status']}';
    final editable = status != 'done';
    final id = '${it['file_id']}';
    final edited = _edits.containsKey(id);
    final sel = _sel.contains(id);
    final sn = int.tryParse('${m['season']}') ?? 0;
    final ep = int.tryParse('${m['episode']}') ?? 0;
    final se = _category == 'series' && (sn > 0 || ep > 0)
        ? '  ·  ${[if (sn > 0) 'S$sn', if (ep > 0) 'E$ep'].join(' ')}'
        : '';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: !editable
          ? null
          : (_selecting ? () => _toggle(id) : () => _edit(it)),
      onLongPress: editable ? () => _toggle(id) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: sel ? Neo.cyan.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          if (_selecting && editable) ...[_check(sel), const SizedBox(width: 8)],
          Icon(Icons.circle,
              size: 8,
              color: status == 'new'
                  ? Neo.cyan
                  : status == 'done'
                      ? Colors.greenAccent
                      : status == 'failed'
                          ? Neo.pink
                          : Neo.muted),
          const SizedBox(width: 8),
          Expanded(child: _txt('${m['title']}$se', s: 12)),
          if (editable)
            Icon(edited ? Icons.edit_note_rounded : Icons.edit_outlined,
                size: 18, color: edited ? Neo.amber : Neo.muted),
        ]),
      ),
    );
  }

  Widget _statusCard() {
    final done = (_st['done'] as num?)?.toInt() ?? 0;
    final failed = (_st['failed'] as num?)?.toInt() ?? 0;
    final total = (_st['new'] as num?)?.toInt() ?? 0;
    final q = (_st['queue'] as Map?) ?? const {};
    final failures = ((_st['failures'] as List?) ?? const []).cast<Map>();
    final log = ((_st['log'] as List?) ?? const []).cast<String>();
    final state = '${_st['state']}'.toUpperCase();
    final err = '${_st['error'] ?? ''}';
    return _card([
      Row(children: [
        _txt(state, c: _running ? Neo.cyan : Neo.amber, s: 14),
        const Spacer(),
        IconButton(
          onPressed: () => _refresh(),
          icon: const Icon(Icons.refresh_rounded, color: Neo.muted, size: 20),
        ),
      ]),
      if (_running) ...[
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: total > 0 ? ((done + failed) / total).clamp(0.0, 1.0) : null,
          color: Neo.cyan,
          backgroundColor: Colors.white12,
        ),
        const SizedBox(height: 8),
        if ('${_st['current']}'.isNotEmpty)
          _txt('Now: ${_st['current']}', c: Neo.muted, s: 12),
      ],
      const SizedBox(height: 8),
      _txt('This run: $done done, $failed failed'
          '${total > 0 ? ' of $total new' : ''}'),
      const SizedBox(height: 4),
      _txt(
          'Queue: ${q['done'] ?? 0} done · ${q['pending'] ?? 0} pending · '
          '${q['failed'] ?? 0} failed · ${q['total'] ?? 0} total',
          c: Neo.muted,
          s: 12),
      if (err.isNotEmpty) ...[
        const SizedBox(height: 8),
        _txt(err, c: Neo.pink, s: 12),
      ],
      if (failures.isNotEmpty) ...[
        const SizedBox(height: 10),
        _txt('Failed', c: Neo.pink, s: 12),
        for (final f in failures.reversed.take(5))
          _txt('${f['name']}: ${f['error']}', c: Neo.pink, s: 11),
      ],
      if (!_running && ((q['failed'] as num?) ?? 0) > 0) ...[
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: _busy ? null : _retryFailed,
          icon: const Icon(Icons.replay_rounded, color: Neo.amber),
          label: _txt('Reset failed videos for retry', c: Neo.amber),
        ),
      ],
      if (log.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 180),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            reverse: true,
            child: _txt(log.join('\n'), c: Neo.muted, s: 10.5, mono: true),
          ),
        ),
      ],
    ]);
  }
}

/// Edit sheet for one collected video. Pops a map with every field's current value.
class _EditForm extends StatefulWidget {
  final Map<String, dynamic> item;
  final bool series;
  const _EditForm({required this.item, required this.series});

  @override
  State<_EditForm> createState() => _EditFormState();
}

class _EditFormState extends State<_EditForm> {
  late final Map<String, TextEditingController> _c = {
    for (final k in const [
      'title', 'season', 'episode', 'series_name', 'video_url', 'thumbnail_url', 'description'
    ])
      k: TextEditingController(text: '${widget.item[k] ?? ''}'),
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
    if (v('title').isEmpty) return setState(() => _err = 'Title is required.');
    if (!_http(v('video_url'))) {
      return setState(() => _err = 'Video URL must start with http(s)://');
    }
    if (v('thumbnail_url').isNotEmpty && !_http(v('thumbnail_url'))) {
      return setState(() => _err = 'Thumbnail URL must start with http(s)://');
    }
    final season = int.tryParse(v('season').isEmpty ? '0' : v('season'));
    final episode = int.tryParse(v('episode').isEmpty ? '0' : v('episode'));
    if (widget.series &&
        (season == null || episode == null || season < 0 || episode < 0)) {
      return setState(() => _err = 'Season / episode must be numbers.');
    }
    Navigator.pop(context, <String, dynamic>{
      'title': v('title'),
      if (widget.series) 'season': season,
      if (widget.series) 'episode': episode,
      'series_name': v('series_name'),
      'video_url': v('video_url'),
      'thumbnail_url': v('thumbnail_url'),
      'description': v('description'),
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          NeoInput(controller: _c['title']!, label: 'Title', icon: Icons.title_rounded),
          const SizedBox(height: 10),
          if (widget.series) ...[
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
                controller: _c['series_name']!,
                label: 'Series / playlist name',
                icon: Icons.playlist_play_rounded),
            const SizedBox(height: 10),
          ],
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
          NeoButton(label: 'SAVE CHANGES', icon: Icons.check_rounded, onTap: _save),
        ]),
      );
}


/// Bulk edit sheet: same fields as the single edit sheet.
/// A blank field keeps each video's own value; a filled field is applied to every selected video.
class _BulkEditForm extends StatefulWidget {
  final bool series;
  const _BulkEditForm({required this.series});

  @override
  State<_BulkEditForm> createState() => _BulkEditFormState();
}

class _BulkEditFormState extends State<_BulkEditForm> {
  final Map<String, TextEditingController> _c = {
    for (final k in const [
      'find', 'replace', 'title', 'season', 'episode',
      'series_name', 'video_url', 'thumbnail_url', 'description'
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
        'title', 'season', 'episode', 'series_name',
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
            if (widget.series) ...[
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
                  controller: _c['series_name']!,
                  label: 'Series / playlist name',
                  icon: Icons.playlist_play_rounded),
              const SizedBox(height: 10),
            ],
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