enum DlState { queued, running, paused, failed, done }

/// One download (persisted locally; the file itself lives in app-private storage).
class DownloadRecord {
  final String id; // taskId == "<videoId>" or "<videoId>__<lang>"
  final String videoId;
  final String uid;
  final String title;
  final String subtitle; // e.g. "S1 · EP 3 · EN"
  final String thumbnail;
  final String filename;
  final DlState state;
  final double progress; // 0..1
  final int bytes;
  final int total; // -1 = unknown
  final double speedMBps; // -1 = unknown
  final String error;
  final int createdAt;
  final bool gallery; // a copy was saved to the device Gallery / Photos
  final String dir; // '' = app storage (default), otherwise the absolute folder chosen by the user

  const DownloadRecord({
    required this.id,
    required this.videoId,
    required this.uid,
    required this.title,
    this.subtitle = '',
    this.thumbnail = '',
    required this.filename,
    this.state = DlState.queued,
    this.progress = 0,
    this.bytes = 0,
    this.total = -1,
    this.speedMBps = -1,
    this.error = '',
    required this.createdAt,
    this.gallery = false,
    this.dir = '',
  });

  bool get isActive => state == DlState.queued || state == DlState.running;
  bool get isDone => state == DlState.done;

  DownloadRecord copyWith({
    DlState? state,
    double? progress,
    int? bytes,
    int? total,
    double? speedMBps,
    String? error,
    bool? gallery,
  }) =>
      DownloadRecord(
        id: id,
        videoId: videoId,
        uid: uid,
        title: title,
        subtitle: subtitle,
        thumbnail: thumbnail,
        filename: filename,
        state: state ?? this.state,
        progress: progress ?? this.progress,
        bytes: bytes ?? this.bytes,
        total: total ?? this.total,
        speedMBps: speedMBps ?? this.speedMBps,
        error: error ?? this.error,
        createdAt: createdAt,
        gallery: gallery ?? this.gallery,
        dir: dir,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'videoId': videoId,
        'uid': uid,
        'title': title,
        'subtitle': subtitle,
        'thumbnail': thumbnail,
        'filename': filename,
        'state': state.name,
        'progress': progress,
        'bytes': bytes,
        'total': total,
        'error': error,
        'createdAt': createdAt,
        'gallery': gallery,
        'dir': dir,
      };

  static DownloadRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return DownloadRecord(
        id: j['id'] as String,
        videoId: j['videoId'] as String,
        uid: j['uid'] as String,
        title: (j['title'] ?? '') as String,
        subtitle: (j['subtitle'] ?? '') as String,
        thumbnail: (j['thumbnail'] ?? '') as String,
        filename: j['filename'] as String,
        state: DlState.values.firstWhere((s) => s.name == j['state'],
            orElse: () => DlState.failed),
        progress: ((j['progress'] ?? 0) as num).toDouble(),
        bytes: ((j['bytes'] ?? 0) as num).toInt(),
        total: ((j['total'] ?? -1) as num).toInt(),
        error: (j['error'] ?? '') as String,
        createdAt: ((j['createdAt'] ?? 0) as num).toInt(),
        gallery: j['gallery'] == true,
        dir: (j['dir'] ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Result of [DownloadService.start] / resume etc. `ok == false` -> show [message].
class DlResult {
  final bool ok;
  final String message;
  const DlResult(this.ok, [this.message = '']);
}

String fmtBytes(num b) {
  if (b < 0) return '--';
  const u = ['B', 'KB', 'MB', 'GB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i >= 2 ? 1 : 0)} ${u[i]}';
}
