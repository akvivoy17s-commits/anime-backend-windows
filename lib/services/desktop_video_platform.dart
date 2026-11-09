import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Windows video backend: same as video_player_media_kit's player, plus
/// audio-track listing/selection (multi-language files) which that package lacks.
/// Registered only on Windows from main.dart.
class AudioAwareMediaKitPlayer extends VideoPlayerPlatform {
  final _players = HashMap<int, Player>();
  final _completers = HashMap<int, Completer<void>>();
  final _videoControllers = HashMap<int, VideoController>();
  final _streamControllers = HashMap<int, StreamController<VideoEvent>>();
  final _streamSubscriptions = HashMap<int, List<StreamSubscription>>();

  static void register() {
    VideoPlayerPlatform.instance = AudioAwareMediaKitPlayer();
  }

  // ------------------------------------------------------------------
  // AUDIO TRACKS (multi-language)
  // ------------------------------------------------------------------

  @override
  bool isAudioTrackSupportAvailable() => true;

  List<AudioTrack> _real(List<AudioTrack> all) =>
      all.where((t) => t.id != 'auto' && t.id != 'no').toList();

  @override
  Future<List<VideoAudioTrack>> getAudioTracks(int playerId) async {
    final player = _players[playerId];
    if (player == null) return const [];
    var list = _real(player.state.tracks.audio);
    if (list.isEmpty) {
      try {
        final t = await player.stream.tracks
            .firstWhere((t) => _real(t.audio).isNotEmpty)
            .timeout(const Duration(seconds: 3));
        list = _real(t.audio);
      } catch (_) {}
    }
    final cur = player.state.track.audio.id;
    final noCur = !list.any((t) => t.id == cur); // 'auto' -> first track plays
    return [
      for (var i = 0; i < list.length; i++)
        VideoAudioTrack(
          id: list[i].id,
          label: list[i].title,
          language: list[i].language,
          isSelected: noCur ? i == 0 : list[i].id == cur,
        ),
    ];
  }

  @override
  Future<void> selectAudioTrack(int playerId, String trackId) async {
    final player = _players[playerId];
    if (player == null) return;
    final t = player.state.tracks.audio.firstWhere((e) => e.id == trackId);
    await player.setAudioTrack(t);
  }

  // ------------------------------------------------------------------
  // BELOW: unchanged copy of video_player_media_kit's MediaKitVideoPlayer
  // ------------------------------------------------------------------

  @override
  Future<void> init() async {
    for (final textureId in _players.keys.toList()) {
      await dispose(textureId);
    }
    _players.clear();
    _videoControllers.clear();
    _streamControllers.clear();
    _streamSubscriptions.clear();
  }

  @override
  Future<void> dispose(int textureId) async {
    await _players[textureId]?.dispose();
    await _streamControllers[textureId]?.close();
    await Future.wait(
      _streamSubscriptions[textureId]?.map((e) => e.cancel()) ?? [],
    );
    _players.remove(textureId);
    _completers.remove(textureId);
    _videoControllers.remove(textureId);
    _streamControllers.remove(textureId);
    _streamSubscriptions.remove(textureId);
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final player = Player();
    final completer = Completer<void>();
    final videoController = VideoController(player);
    final streamController = StreamController<VideoEvent>();
    final streamSubscriptions = <StreamSubscription>[];
    final textureId = player.hashCode;

    _players[textureId] = player;
    _completers[textureId] = completer;
    _videoControllers[textureId] = videoController;
    _streamControllers[textureId] = streamController;
    _streamSubscriptions[textureId] = streamSubscriptions;

    _initialize(textureId);

    final String resource;
    final Map<String, String> httpHeaders = dataSource.httpHeaders;
    switch (dataSource.sourceType) {
      case DataSourceType.asset:
        final String? asset;
        if (dataSource.package == null) {
          asset = dataSource.asset;
        } else {
          asset = 'packages/${dataSource.package}/${dataSource.asset}';
        }
        resource = 'asset:///$asset';
        break;
      case DataSourceType.network:
      case DataSourceType.file:
      case DataSourceType.contentUri:
        resource = dataSource.uri!;
        break;
      default:
        throw UnsupportedError('${dataSource.sourceType} is not supported');
    }

    await player.open(
      Media(resource, httpHeaders: httpHeaders),
      play: false,
    );
    return textureId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) =>
      _streamControllers[textureId]!.stream;

  @override
  Future<void> setLooping(int textureId, bool looping) async {
    final mode = looping ? PlaylistMode.single : PlaylistMode.none;
    return _players[textureId]?.setPlaylistMode(mode);
  }

  @override
  Future<void> play(int textureId) async => _players[textureId]?.play();

  @override
  Future<void> pause(int textureId) async => _players[textureId]?.pause();

  @override
  Future<void> setVolume(int textureId, double volume) async =>
      _players[textureId]?.setVolume(volume * 100);

  @override
  Future<void> seekTo(int textureId, Duration position) async =>
      _players[textureId]?.seek(position);

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async =>
      _players[textureId]?.setRate(speed);

  @override
  Future<Duration> getPosition(int textureId) async =>
      _players[textureId]?.platform?.state.position ?? Duration.zero;

  @override
  Widget buildView(int textureId) {
    return Video(
      key: ValueKey(_videoControllers[textureId]!),
      controller: _videoControllers[textureId]!,
      wakelock: false,
      controls: NoVideoControls,
      fill: const Color(0x00000000),
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
    );
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => Future.value();

  @override
  Future<void> setWebOptions(int textureId, VideoPlayerWebOptions options) =>
      Future.value();

  void _initialize(int textureId) {
    if (_streamSubscriptions[textureId]?.isNotEmpty ?? false) return;

    final player = _players[textureId];
    final completer = _completers[textureId];
    final streamController = _streamControllers[textureId];
    final subs = _streamSubscriptions[textureId];
    if (player == null || completer == null || streamController == null || subs == null) {
      return;
    }

    int? width;
    int? height;
    Duration? duration;

    void notify() {
      if (!completer.isCompleted && width != null && height != null && duration != null) {
        streamController.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            size: Size((width ?? 0) * 1.0, (height ?? 0) * 1.0),
            duration: player.state.duration,
          ),
        );
        completer.complete();
      }
    }

    subs.add(player.stream.duration.listen((e) {
      if (e > Duration.zero) {
        duration = e;
        notify();
      }
    }));
    subs.add(player.stream.videoParams.listen((e) {
      width = e.dw;
      height = e.dh;
      if ((width ?? 0) > 0 && (height ?? 0) > 0) notify();
    }));
    subs.add(player.stream.tracks.listen((e) {
      // no video track (audio file)
      if (e.video.length == 2 && e.audio.length > 2) {
        width = 0;
        height = 0;
        notify();
      }
    }));
    subs.add(player.stream.playing.listen((e) async {
      await completer.future;
      streamController.add(VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: e,
      ));
    }));
    subs.add(player.stream.completed.listen((e) async {
      await completer.future;
      if (e) streamController.add(VideoEvent(eventType: VideoEventType.completed));
    }));
    subs.add(player.stream.buffering.listen((e) async {
      await completer.future;
      streamController.add(VideoEvent(
        eventType: e ? VideoEventType.bufferingStart : VideoEventType.bufferingEnd,
      ));
    }));
    subs.add(player.stream.buffer.listen((e) async {
      await completer.future;
      streamController.add(VideoEvent(
        eventType: VideoEventType.bufferingUpdate,
        buffered: [DurationRange(Duration.zero, e)],
      ));
    }));
    subs.add(player.stream.error.listen((e) async {
      await completer.future;
      streamController.addError(PlatformException(code: '', message: e));
    }));
  }
}
