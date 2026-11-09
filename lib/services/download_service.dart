import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:gal/gal.dart';
import 'platform_flags.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'admin_service.dart';
import 'api_client.dart';
import 'download_models.dart';
import 'session_service.dart';

/// Real downloads (background_downloader: native WorkManager / URLSession, HTTP Range resume).
/// Files go to app-private storage: <appSupport>/anime_downloads/<id>.<ext>.
/// Records live in SharedPreferences and are reconciled with the native task DB + the real files.
class DownloadService {
  DownloadService._();

  static const _prefKey = 'dl_records_v1';
  static const _dir = 'anime_downloads';
  static const _locKey = 'dl_location_v1';
  static const _group = 'anime_videos';
  static const disabledMsg = 'Downloads are currently disabled by the administrator.';

  /// All records on this device (all accounts). Use [forCurrentUser] for display.
  static final ValueNotifier<Map<String, DownloadRecord>> records = ValueNotifier({});

  /// Where NEW downloads are saved: '' = app storage (default), otherwise an absolute folder.
  static final ValueNotifier<String> location = ValueNotifier('');

  /// Bumped when the user taps a download notification -> HomePage switches to the Downloads tab.
  static final ValueNotifier<int> openDownloadsTab = ValueNotifier(0);

  /// True when a notification tap arrived before HomePage existed (app was closed) -> HomePage consumes it.
  static bool openDownloadsPending = false;

  static void _onNotificationTap(Task task, NotificationType type) {
    openDownloadsPending = true;
    openDownloadsTab.value++;
  }

  static bool _inited = false;
  static String? _uid;
  static StreamSubscription<User?>? _authSub;
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _settingsSub;
  static Timer? _persistTimer;
  static final Set<String> _locks = {};

  // ------------------------------------------------------------------ public views
  static List<DownloadRecord> forCurrentUser() {
    final uid = _uid;
    final l = records.value.values.where((r) => r.uid == uid).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }

  static DownloadRecord? recordFor(String id) {
    final r = records.value[id];
    return (r != null && r.uid == _uid) ? r : null;
  }

  static String keyFor(String videoId, [String variant = '']) =>
      variant.isEmpty ? videoId : '${videoId}__$variant';

  /// Absolute path of a finished file (null if the file is gone).
  static Future<String?> localPath(DownloadRecord r) async {
    final p = await _taskFor(r.id, r.filename, 'x://x', dir: r.dir).filePath();
    return File(p).existsSync() ? p : null;
  }

  static bool get canDownload => AdminService.isAdmin || SessionService.allowDownloads.value;

  // ------------------------------------------------------------------ init
  static Future<void> init() async {
    if (_inited) return;
    _inited = true;
    // Register FIRST (before any await): a notification tap that launched the app must never be missed.
    try {
      FileDownloader().registerCallbacks(group: _group, taskNotificationTapCallback: _onNotificationTap);
      FileDownloader().registerCallbacks(taskNotificationTapCallback: _onNotificationTap);
    } catch (e) {
      debugPrint('DownloadService.registerCallbacks: $e');
    }
    try {
      await _load();
      try {
        final prefs = await SharedPreferences.getInstance();
        location.value = prefs.getString(_locKey) ?? '';
      } catch (_) {}
      FileDownloader().configureNotification(
        running: const TaskNotification('Downloading', '{displayName}'),
        complete: const TaskNotification('Download complete', '{displayName}'),
        error: const TaskNotification('Download failed', '{displayName}'),
        paused: const TaskNotification('Download paused', '{displayName}'),
        progressBar: true,
      );
      FileDownloader().configureNotificationForGroup(
        _group,
        running: const TaskNotification('Downloading', '{displayName}'),
        complete: const TaskNotification('Download complete', '{displayName}'),
        error: const TaskNotification('Download failed', '{displayName}'),
        paused: const TaskNotification('Download paused', '{displayName}'),
        progressBar: true,
      );
      await FileDownloader().configure(androidConfig: [
        (Config.runInForegroundIfFileLargerThan, 100), // MB; long downloads survive the 9-min WorkManager limit
      ]);
      await FileDownloader().trackTasks();
      FileDownloader().updates.listen(_onUpdate);
      await FileDownloader().resumeFromBackground();
    } catch (e) {
      debugPrint('DownloadService.init: $e');
    }

    _authSub = FirebaseAuth.instance.authStateChanges().listen((u) {
      _uid = u?.uid;
      records.value = Map.of(records.value); // refresh listeners (visible set changed)
      _settingsSub?.cancel();
      _settingsSub = null;
      if (u != null) {
        // Live admin toggle (settings/app is readable by every signed-in user).
        _settingsSub = FirebaseFirestore.instance.collection('settings').doc('app').snapshots().listen(
          (s) {
            final v = s.data()?['allowDownloads'];
            if (v is bool) SessionService.setGlobalAllow(v);
          },
          onError: (_) {},
        );
        _reconcile();
      }
    });
    _uid = FirebaseAuth.instance.currentUser?.uid;
    SessionService.allowDownloads.addListener(_onPermissionChanged);
    AdminService.notifier.addListener(_onPermissionChanged);
    if (_uid != null) _reconcile();
  }

  // ------------------------------------------------------------------ start
  static Future<DlResult> start({
    required String videoId,
    String variant = '',
    required String url,
    required String title,
    String subtitle = '',
    String thumbnail = '',
  }) async {
    final uid = _uid;
    if (uid == null) return const DlResult(false, 'Please sign in again.');
    final id = keyFor(videoId, variant);
    if (_locks.contains(id)) return const DlResult(true, 'Download already starting…');
    _locks.add(id);
    try {
      final ex = recordFor(id);
      if (ex != null) {
        if (ex.isDone && await localPath(ex) != null) {
          return const DlResult(true, 'Already downloaded.');
        }
        if (ex.isActive) return const DlResult(true, 'Already downloading.');
        if (ex.state == DlState.paused) return resume(id);
        await _discard(id); // failed / stale -> restart cleanly
      }

      final auth = await _authorize(videoId);
      if (!auth.ok) return auth;

      final src = await _resolve(url);
      final filename = _fileNameFor(id, title, src.ext, subtitle);
      final dir = location.value; // folder chosen by the user ('' = app storage)
      _put(DownloadRecord(
        id: id,
        videoId: videoId,
        uid: uid,
        title: title,
        subtitle: subtitle,
        thumbnail: thumbnail,
        filename: filename,
        dir: dir,
        total: src.total,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await _askNotificationPermissionOnce();
      final ok = await FileDownloader().enqueue(_taskFor(id, filename, src.url, title: title, dir: dir));
      if (!ok) {
        _fail(id, 'Could not start the download.');
        return const DlResult(false, 'Could not start the download.');
      }
      return const DlResult(true, 'Download started.');
    } on _DlError catch (e) {
      return DlResult(false, e.message);
    } catch (e) {
      return DlResult(false, 'Could not start the download: $e');
    } finally {
      _locks.remove(id);
    }
  }

  // ------------------------------------------------------------------ controls
  static Future<DlResult> pause(String id) async {
    final r = records.value[id];
    if (r == null || !r.isActive) return const DlResult(false, 'Nothing to pause.');
    final t = await FileDownloader().taskForId(id);
    if (t is DownloadTask && await FileDownloader().pause(t)) {
      _set(id, (x) => x.copyWith(state: DlState.paused, speedMBps: -1, error: ''));
      return const DlResult(true);
    }
    return const DlResult(false, "This server doesn't allow pausing. You can cancel and restart instead.");
  }

  static Future<DlResult> resume(String id) async {
    final r = records.value[id];
    if (r == null) return const DlResult(false, 'Download not found.');
    if (_locks.contains(id)) return const DlResult(true);
    _locks.add(id);
    try {
      final auth = await _authorize(r.videoId); // permission may have changed while paused
      if (!auth.ok) return auth;
      final t = await FileDownloader().taskForId(id) ??
          (await FileDownloader().database.recordForId(id))?.task;
      if (t is DownloadTask && await FileDownloader().resume(t)) {
        _set(id, (x) => x.copyWith(state: DlState.running, error: ''));
        return const DlResult(true);
      }
      // Nothing resumable (e.g. link expired / data lost): restart from the beginning.
      final old = r;
      await _discard(id);
      return start(
        videoId: old.videoId,
        variant: old.id == old.videoId ? '' : old.id.substring(old.videoId.length + 2),
        url: await _sourceUrlFor(old.videoId) ?? '',
        title: old.title,
        subtitle: old.subtitle,
        thumbnail: old.thumbnail,
      );
    } on _DlError catch (e) {
      return DlResult(false, e.message);
    } finally {
      _locks.remove(id);
    }
  }

  static Future<void> cancel(String id) async {
    await FileDownloader().cancelTaskWithId(id);
    await _discard(id);
  }

  /// Delete a finished download (file + record).
  static Future<void> delete(String id) => _discard(id);

  // ------------------------------------------------------------------ authorization
  static Future<DlResult> _authorize(String videoId) async {
    if (!canDownload) return const DlResult(false, disabledMsg);
    try {
      await ApiClient.call('POST', '/downloads/authorize',
          body: {'videoId': videoId, 'deviceId': await SessionService.deviceId()},
          timeout: const Duration(seconds: 20));
      return const DlResult(true);
    } on ApiException catch (e) {
      if (e.status == 403) {
        SessionService.allowDownloads.value = false;
        return const DlResult(false, disabledMsg);
      }
      if (e.isNetwork) return const DlResult(false, 'No connection to the server. Check your internet and try again.');
      return DlResult(false, e.message);
    }
  }

  // ------------------------------------------------------------------ native updates
  static void _onUpdate(TaskUpdate u) {
    final id = u.task.taskId;
    final r = records.value[id];
    if (r == null) return;
    if (u is TaskStatusUpdate) {
      switch (u.status) {
        case TaskStatus.enqueued:
          if (r.state != DlState.paused) _set(id, (x) => x.copyWith(state: DlState.queued), persist: true);
        case TaskStatus.running:
        case TaskStatus.waitingToRetry:
          _set(id, (x) => x.copyWith(state: DlState.running, error: ''), persist: true);
        case TaskStatus.paused:
          _set(id, (x) => x.copyWith(state: DlState.paused, speedMBps: -1), persist: true);
        case TaskStatus.complete:
          unawaited(_complete(id));
        case TaskStatus.canceled:
          unawaited(_discard(id)); // e.g. cancelled from the notification
        case TaskStatus.notFound:
          _fail(id, 'The video file was not found on the server.');
        case TaskStatus.failed:
          _fail(id, _explain(u));
      }
    } else if (u is TaskProgressUpdate) {
      if (u.progress < 0 || r.state == DlState.paused) return; // negative = status markers
      final total = u.expectedFileSize > 0 ? u.expectedFileSize : r.total;
      _set(id, (x) => x.copyWith(
            state: DlState.running,
            progress: u.progress.clamp(0.0, 1.0).toDouble(),
            total: total,
            bytes: total > 0 ? (u.progress * total).round() : x.bytes,
            speedMBps: u.hasNetworkSpeed ? u.networkSpeed : -1,
          ));
    }
  }

  static String _explain(TaskStatusUpdate u) {
    final code = u.responseStatusCode ?? 0;
    if (code == 403 || code == 429) {
      return 'Google Drive refused the download (daily quota reached or file not shared). Try again later.';
    }
    if (code == 404) return 'The video file was not found on the server.';
    final d = u.exception?.description ?? '';
    if (u.exception is TaskConnectionException) return 'Connection lost. Tap Resume to continue.';
    return d.isEmpty ? 'Download failed.' : d;
  }

  static Future<void> _complete(String id) async {
    final r = records.value[id];
    if (r == null) return;
    final path = await _taskFor(id, r.filename, 'x://x', dir: r.dir).filePath();
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() == 0) return _fail(id, 'Downloaded file is missing.');
    // Drive sometimes answers 200 with an HTML error page: never keep that as a "video".
    final head = await f.openRead(0, 512).fold<List<int>>([], (a, b) => a..addAll(b));
    final s = latin1.decode(head).toLowerCase();
    if (s.contains('<!doctype html') || s.contains('<html')) {
      await _deleteFile(path);
      return _fail(id, 'Google Drive returned an error page instead of the video (quota or permission).');
    }
    final len = f.lengthSync();
    _set(id, (x) => x.copyWith(state: DlState.done, progress: 1, bytes: len, total: len, speedMBps: -1, error: ''),
        persist: true);
    if (r.dir.isEmpty) unawaited(saveToGallery(id)); // (a custom folder is already visible to the user) // permission is requested only now (first finished download)
  }

  /// Re-checks records against the real files (call when the Downloads page opens / app resumes).
  static Future<void> syncWithDisk() => _reconcile();

  /// Copies a finished download into the device Gallery / Photos (album "Anime Portal").
  /// Done at most once per download ([DownloadRecord.gallery]); the app-private original stays for offline play.
  static Future<DlResult> saveToGallery(String id) async {
    final r = records.value[id];
    if (r == null || !r.isDone) return const DlResult(false, 'Download is not finished yet.');
    if (isWindows) return const DlResult(true, 'Saved on your PC.'); // no Gallery on Windows
    if (r.gallery) return const DlResult(true, 'Already in your Gallery.');
    final path = await localPath(r);
    if (path == null) return const DlResult(false, 'File not found.');
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        if (!await Gal.requestAccess(toAlbum: true)) {
          return const DlResult(false, 'Gallery permission denied. Allow it in system settings to save videos.');
        }
      }
      await Gal.putVideo(path, album: 'Anime Portal');
      _set(id, (x) => x.copyWith(gallery: true), persist: true);
      return const DlResult(true, 'Saved to Gallery.');
    } on GalException catch (e) {
      return DlResult(false, 'Could not save to Gallery: ${e.type.message}');
    } catch (_) {
      return DlResult(false, 'Could not save to Gallery.');
    }
  }

  // ------------------------------------------------------------------ policy: admin turned downloads off
  /// Running/queued downloads are paused (partial data kept); resuming re-checks permission.
  static void _onPermissionChanged() {
    if (canDownload) return;
    for (final r in records.value.values.where((r) => r.uid == _uid && r.isActive).toList()) {
      unawaited(() async {
        final res = await pause(r.id);
        if (!res.ok) {
          await FileDownloader().cancelTaskWithId(r.id);
          _fail(r.id, disabledMsg);
        } else {
          _set(r.id, (x) => x.copyWith(error: disabledMsg), persist: true);
        }
      }());
    }
  }

  // ------------------------------------------------------------------ reconcile with native DB + disk
  static Future<void> _reconcile() async {
    for (final r in records.value.values.toList()) {
      if (r.uid != _uid) continue;
      try {
        if (r.isDone) {
          if (await localPath(r) == null) await _discard(r.id); // file deleted outside the app
          continue;
        }
        final rec = await FileDownloader().database.recordForId(r.id);
        if (rec == null) {
          if (await FileDownloader().taskForId(r.id) == null) _fail(r.id, 'Interrupted. Tap Retry.');
          continue;
        }
        switch (rec.status) {
          case TaskStatus.complete:
            await _complete(r.id);
          case TaskStatus.paused:
            _set(r.id, (x) => x.copyWith(state: DlState.paused), persist: true);
          case TaskStatus.enqueued:
          case TaskStatus.running:
          case TaskStatus.waitingToRetry:
            _set(r.id, (x) => x.copyWith(state: DlState.running));
          default:
            _fail(r.id, 'Download failed. Tap Retry.');
        }
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------------ download location
  /// Ready-made folders offered in the "Download location" sheet (Android only).
  static Map<String, String> get presetFolders {
    if (isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? '';
      if (home.isEmpty) return const {};
      return {
        'Videos / Anime Portal': '$home\\Videos\\Anime Portal',
        'Downloads / Anime Portal': '$home\\Downloads\\Anime Portal',
      };
    }
    return const {
      'Movies / Anime Portal': '/storage/emulated/0/Movies/Anime Portal',
      'Download / Anime Portal': '/storage/emulated/0/Download/Anime Portal',
    };
  }

  /// The default (app-private) folder, as a readable path.
  static Future<String> defaultFolder() async {
    try {
      final p = await DownloadTask(url: 'x://x', filename: 'x', directory: _dir, baseDirectory: BaseDirectory.applicationSupport)
          .filePath();
      return File(p).parent.path;
    } catch (_) {
      return 'App storage';
    }
  }

  /// Folder that new downloads go to right now (for display).
  static Future<String> currentFolder() async => location.value.isEmpty ? defaultFolder() : location.value;

  /// Sets the folder for NEW downloads ('' = back to app storage). Already finished downloads stay where they are.
  static Future<DlResult> setLocation(String path) async {
    var p = path.trim();
    while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
      p = p.substring(0, p.length - 1);
    }
    if (p.isNotEmpty) {
      final okPath = isWindows ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) : p.startsWith('/');
      if (!okPath) {
        return DlResult(false,
            isWindows ? r'Enter a full folder path, e.g. C:\Users\you\Videos\Anime Portal'
                      : 'Enter a full folder path, e.g. /storage/emulated/0/Movies/Anime Portal');
      }
      try {
        final d = Directory(p);
        if (!d.existsSync()) d.createSync(recursive: true);
        final t = File('$p${Platform.pathSeparator}.anime_portal_test.mp4'); // a video-type file, like the real downloads
        t.writeAsBytesSync(const [0]);
        t.deleteSync();
      } catch (_) {
        return const DlResult(
            false,
            "This folder can't be written by the app. Try Movies / Anime Portal, or allow "
            "\"All files access\" for this app in the phone Settings and try again.");
      }
    }
    location.value = p;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_locKey, p);
    } catch (_) {}
    return const DlResult(true);
  }

  // ------------------------------------------------------------------ helpers
  /// File name = the video's title + season/episode (e.g. "Naruto S01E05.mp4"); falls back to the id when the title is empty.
  /// Season / episode come from [subtitle] ("S1 · EP 5 · EN"); nothing is added when the title already has them.
  /// A numeric suffix keeps two downloads with the same title from overwriting each other.
  static String _fileNameFor(String id, String title, String ext, [String subtitle = '']) {
    String clean(String t) => t
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^\.+|\.+$'), '')
        .trim();
    var base = clean(title);
    if (base.length > 110) base = base.substring(0, 110).trim();
    if (base.isEmpty) return '$id.$ext';

    final sn = RegExp(r'(?:^|[\s·])S\w*?\s*(\d+)', caseSensitive: false).firstMatch(subtitle)?.group(1);
    final ep = RegExp(r'EP\w*\s*(\d+)', caseSensitive: false).firstMatch(subtitle)?.group(1);
    String pad(String n) => n.padLeft(2, '0');
    final titleHasSE = RegExp(r'\bS(?:eason)?[\s._-]*\d+[\s._-]*E(?:p|pisode)?[\s._-]*\d+', caseSensitive: false).hasMatch(base);
    final titleHasEp = RegExp(r'\bE(?:p|pisode)?[\s._-]*\d+', caseSensitive: false).hasMatch(base);
    if (!titleHasSE && ep != null && !(titleHasEp && sn == null)) {
      base = sn != null ? '$base S${pad(sn)}E${pad(ep)}' : '$base EP${pad(ep)}';
    }
    final used = records.value.values.where((r) => r.id != id).map((r) => r.filename.toLowerCase()).toSet();
    var name = '$base.$ext';
    for (var i = 2; used.contains(name.toLowerCase()); i++) {
      name = '$base ($i).$ext';
    }
    return name;
  }

  static DownloadTask _taskFor(String id, String filename, String url, {String title = '', String dir = ''}) => DownloadTask(
        taskId: id,
        url: url,
        filename: filename,
        directory: dir.isEmpty ? _dir : dir,
        baseDirectory: dir.isEmpty ? BaseDirectory.applicationSupport : BaseDirectory.root,
        group: _group,
        updates: Updates.statusAndProgress,
        retries: 3,
        allowPause: true,
        displayName: title,
      );

  static Future<void> _discard(String id) async {
    final r = records.value[id];
    final next = Map.of(records.value)..remove(id);
    records.value = next;
    _persistNow();
    if (r != null) {
      await _deleteFile(await _taskFor(id, r.filename, 'x://x', dir: r.dir).filePath());
    }
    try {
      await FileDownloader().database.deleteRecordWithId(id);
    } catch (_) {}
  }

  static Future<void> _deleteFile(String p) async {
    try {
      final f = File(p);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  static void _fail(String id, String msg) =>
      _set(id, (x) => x.copyWith(state: DlState.failed, error: msg, speedMBps: -1), persist: true);

  static void _put(DownloadRecord r) {
    records.value = {...records.value, r.id: r};
    _persistNow();
  }

  static void _set(String id, DownloadRecord Function(DownloadRecord) f, {bool persist = false}) {
    final r = records.value[id];
    if (r == null) return;
    records.value = {...records.value, id: f(r)};
    if (persist) {
      _persistNow();
    } else {
      _persistTimer ??= Timer(const Duration(seconds: 3), _persistNow);
    }
  }

  static Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefKey);
      if (raw == null) return;
      final m = <String, DownloadRecord>{};
      for (final j in (jsonDecode(raw) as List)) {
        final r = DownloadRecord.fromJson(j);
        if (r != null) m[r.id] = r;
      }
      records.value = m;
    } catch (_) {}
  }

  static void _persistNow() {
    _persistTimer?.cancel();
    _persistTimer = null;
    SharedPreferences.getInstance().then((p) =>
        p.setString(_prefKey, jsonEncode(records.value.values.map((r) => r.toJson()).toList())));
  }

  static Future<void> _askNotificationPermissionOnce() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool('dl_notif_asked') == true) return;
      await p.setBool('dl_notif_asked', true);
      final st = await FileDownloader().permissions.status(PermissionType.notifications);
      if (st != PermissionStatus.granted) {
        await FileDownloader().permissions.request(PermissionType.notifications);
      }
    } catch (_) {}
  }

  static Future<String?> _sourceUrlFor(String videoId) async {
    try {
      final d = await FirebaseFirestore.instance.collection('videos').doc(videoId).get();
      final m = d.data() ?? {};
      for (final k in ['videoUrl', 'url', 'videoURL']) {
        final v = m[k]?.toString().trim() ?? '';
        if (v.isNotEmpty) return v;
      }
    } catch (_) {}
    return null;
  }

  // ------------------------------------------------------------------ Drive-aware URL resolution
  static String? driveId(String url) {
    try {
      final u = Uri.parse(url);
      final i = u.pathSegments.indexOf('d');
      if (i != -1 && i + 1 < u.pathSegments.length && u.pathSegments[i + 1].isNotEmpty) {
        return u.pathSegments[i + 1];
      }
      final q = u.queryParameters['id'];
      return (q != null && q.isNotEmpty) ? q : null;
    } catch (_) {
      return null;
    }
  }

  static List<String> _candidates(String original) {
    final c = <String>[];
    void add(String s) {
      if (s.isNotEmpty && !c.contains(s)) c.add(s);
    }

    final clean = original.trim();
    final id = driveId(clean);
    if (id != null && clean.contains('google.com')) {
      // usercontent + confirm=t skips the "can't scan for viruses" page for big files
      add('https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t');
      add('https://drive.google.com/uc?export=download&confirm=t&id=$id');
      add('https://drive.google.com/uc?export=download&id=$id');
    }
    add(clean);
    return c;
  }

  /// Probes each candidate with `Range: bytes=0-0`: finds a link that serves real bytes (not an HTML
  /// page), the total size and the file type, without downloading the video.
  static Future<_Source> _resolve(String original) async {
    if (original.trim().isEmpty) throw const _DlError('This video has no download link.');
    String? why;
    var offline = false;
    for (final url in _candidates(original)) {
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url))..headers['Range'] = 'bytes=0-0';
        final resp = await client.send(req).timeout(const Duration(seconds: 25));
        final ct = (resp.headers['content-type'] ?? '').toLowerCase();
        if ((resp.statusCode == 200 || resp.statusCode == 206) && !ct.contains('text/html')) {
          var total = -1;
          final cr = RegExp(r'/(\d+)\s*$').firstMatch(resp.headers['content-range'] ?? '');
          if (cr != null) {
            total = int.parse(cr.group(1)!);
          } else if (resp.statusCode == 200 && resp.contentLength != null) {
            total = resp.contentLength!;
          }
          return _Source(url, total, _ext(resp.headers['content-disposition'] ?? '', ct));
        }
        if (ct.contains('text/html')) {
          final body = await resp.stream.bytesToString().timeout(const Duration(seconds: 10), onTimeout: () => '');
          if (body.toLowerCase().contains('quota')) why = 'quota';
        } else if (resp.statusCode == 403 || resp.statusCode == 429) {
          why = 'quota';
        }
      } on SocketException {
        offline = true;
      } on TimeoutException {
        why ??= 'timeout';
      } catch (_) {
        why ??= 'error';
      } finally {
        client.close();
      }
    }
    if (offline && why == null) throw const _DlError('No internet connection.');
    if (why == 'quota') {
      throw const _DlError('Google Drive download quota reached for this file. Please try again later.');
    }
    throw const _DlError('Could not reach the video file. Check your connection or try again later.');
  }

  static String _ext(String disposition, String ct) {
    final m = RegExp(r'filename\*?=(?:UTF-8\x27\x27)?"?([^";]+)"?', caseSensitive: false).firstMatch(disposition);
    final name = m?.group(1)?.toLowerCase() ?? '';
    for (final e in ['mp4', 'mkv', 'webm', 'mov', 'm4v']) {
      if (name.endsWith('.$e')) return e;
    }
    if (ct.contains('webm')) return 'webm';
    if (ct.contains('matroska')) return 'mkv';
    if (ct.contains('quicktime')) return 'mov';
    return 'mp4';
  }
}

class _Source {
  final String url;
  final int total;
  final String ext;
  const _Source(this.url, this.total, this.ext);
}

class _DlError implements Exception {
  final String message;
  const _DlError(this.message);
}
