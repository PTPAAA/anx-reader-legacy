import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/edge_tts_api.dart';
import 'package:anx_reader/service/tts/models/tts_segment.dart';
import 'package:anx_reader/service/tts/models/tts_sentence.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

class EdgeTts extends BaseTts {
  static final EdgeTts _instance = EdgeTts._internal();

  factory EdgeTts() {
    return _instance;
  }

  EdgeTts._internal();

  static const int _queueCapacity = 10;

  AudioPlayer? player;
  StreamSubscription<void>? _playerCompleteSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;

  final Queue<TtsSegment> _segmentQueue = Queue<TtsSegment>();
  TtsSegment? _currentSegment;
  String? _currentVoiceText;
  Uint8List? audioToPlay;

  late Function getHereFunction;
  late Function getNextTextFunction;
  late Function getPrevTextFunction;

  bool isInit = false;
  bool _shouldStop = false;
  Future<void>? _queueFillFuture;
  bool _isFetchingAudio = false;
  bool _needsLocationSync = true;

  @override
  final ValueNotifier<TtsStateEnum> ttsStateNotifier =
      ValueNotifier<TtsStateEnum>(TtsStateEnum.stopped);

  @override
  void updateTtsState(TtsStateEnum newState) {
    ttsStateNotifier.value = newState;
  }

  @override
  double get volume => Prefs().ttsVolume;

  @override
  set volume(double volume) {
    restart();
    Prefs().ttsVolume = volume;
  }

  @override
  double get pitch => Prefs().ttsPitch;

  @override
  set pitch(double pitch) {
    restart();
    Prefs().ttsPitch = pitch;
  }

  @override
  double get rate => Prefs().ttsRate;

  @override
  set rate(double rate) {
    restart();
    Prefs().ttsRate = rate;
  }

  @override
  bool get isPlaying => ttsStateNotifier.value == TtsStateEnum.playing;

  @override
  String? get currentVoiceText => _currentVoiceText;

  @override
  Future<void> init(Function getCurrentText, Function getNextText,
      Function getPrevText) async {
    // if (isInit) return;

    getHereFunction = getCurrentText;
    getNextTextFunction = getNextText;
    getPrevTextFunction = getPrevText;

    isInit = true;
    _needsLocationSync = true;
  }

  Future<void> _syncWithLastLocation() async {
    if (!_needsLocationSync) return;
    try {
      await getHereFunction();
    } catch (_) {
      // ignore
    } finally {
      _needsLocationSync = false;
    }
  }

  Future<AudioPlayer> _ensurePlayer() async {
    if (player != null) return player!;

    player = AudioPlayer();
    await player!.setReleaseMode(ReleaseMode.stop);
    await player!.setPlayerMode(PlayerMode.mediaPlayer);
    _playerCompleteSubscription = player!.onPlayerComplete
        .listen((_) => unawaited(_onPlaybackComplete()));
    _playerStateSubscription = player!.onPlayerStateChanged.listen((_) {});
    await player!.setVolume(volume);
    return player!;
  }

  Future<void> _disposePlayer() async {
    await player?.stop();
    await _playerCompleteSubscription?.cancel();
    _playerCompleteSubscription = null;
    await _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    await player?.dispose();
    player = null;
  }

  Future<void> _highlightSegment(TtsSegment segment) async {
    final state = epubPlayerKey.currentState;
    final cfi = segment.sentence.cfi;
    if (state == null || cfi == null || cfi.isEmpty) return;
    try {
      await state.ttsHighlightByCfi(cfi);
    } catch (_) {
      // ignore
    }
  }

  void _resetQueue() {
    _segmentQueue.clear();
    _currentSegment = null;
    _currentVoiceText = null;
    audioToPlay = null;
  }

  int _totalBufferedSegments() =>
      _segmentQueue.length + (_currentSegment == null ? 0 : 1);

  String _sentenceKey(TtsSentence sentence) {
    if (sentence.cfi != null && sentence.cfi!.isNotEmpty) {
      return sentence.cfi!;
    }
    return '${sentence.text}|${sentence.text.hashCode}';
  }

  int _mergeSentences(List<TtsSentence> sentences) {
    if (sentences.isEmpty) return 0;

    final existing = <String>{};
    if (_currentSegment != null) {
      existing.add(_sentenceKey(_currentSegment!.sentence));
    }
    for (final segment in _segmentQueue) {
      existing.add(_sentenceKey(segment.sentence));
    }

    var added = 0;
    for (final sentence in sentences) {
      if (_totalBufferedSegments() >= _queueCapacity) break;
      final key = _sentenceKey(sentence);
      if (existing.contains(key)) continue;
      _segmentQueue.add(TtsSegment(sentence: sentence));
      existing.add(key);
      added += 1;
    }
    return added;
  }

  Future<void> _fetchAudioForQueue() async {
    if (_shouldStop) return;
    if (_isFetchingAudio) return;
    _isFetchingAudio = true;
    try {
      final segments = List<TtsSegment>.from(_segmentQueue);
      for (final segment in segments) {
        if (_shouldStop) break;
        if (segment.isReady) continue;
        final success = await _ensureSegmentAudio(segment);
        if (!success) {
          _segmentQueue.remove(segment);
        }
      }
    } finally {
      _isFetchingAudio = false;
    }
  }

  Future<bool> _ensureSegmentAudio(TtsSegment segment) async {
    if (segment.isReady) return true;
    if (_shouldStop) return false;

    EdgeTTSApi.pitch = pitch;
    EdgeTTSApi.rate = rate;
    EdgeTTSApi.volume = volume;

    try {
      final bytes = await EdgeTTSApi.getAudio(segment.sentence.text);
      if (bytes.isEmpty) {
        segment.audio = Uint8List(0);
        segment.isSilent = true;
        return true;
      }
      segment.audio = bytes;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fillQueueIfNeeded({bool includeCurrent = false}) {
    if (_shouldStop) return Future.value();
    if (_totalBufferedSegments() >= _queueCapacity) return Future.value();
    if (_queueFillFuture != null) return _queueFillFuture!;

    final completer = Completer<void>();
    _queueFillFuture = completer.future;

    () async {
      try {
        final state = epubPlayerKey.currentState;
        if (state == null) return;

        var advanced = false;
        while (!_shouldStop && _totalBufferedSegments() < _queueCapacity) {
          final sentences = await state.ttsCollectDetails(
            count: _queueCapacity,
            includeCurrent: includeCurrent || _currentSegment == null,
          );

          final added = _mergeSentences(sentences);
          if (added == 0) {
            if (advanced || _currentSegment != null) break;
            final dynamic result = await getNextTextFunction();
            if (result is! String || result.isEmpty) {
              break;
            }
            includeCurrent = true;
            advanced = true;
            continue;
          }

          includeCurrent = false;
        }

        if (!_shouldStop) unawaited(_fetchAudioForQueue());
      } catch (e) {
        debugPrint('EdgeTts queue fill error: $e');
      } finally {
        _queueFillFuture = null;
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }();

    return completer.future;
  }

  Future<void> _playNextSegment() async {
    if (_shouldStop) return;

    final audioPlayer = await _ensurePlayer();

    if (_segmentQueue.isEmpty) {
      await _fillQueueIfNeeded(includeCurrent: true);
    }

    while (_segmentQueue.isNotEmpty && !_shouldStop) {
      final segment = _segmentQueue.removeFirst();
      final hasAudio = await _ensureSegmentAudio(segment);
      if (!hasAudio) continue;

      _currentSegment = segment;
      _currentVoiceText = segment.sentence.text;
      audioToPlay = segment.audio;

      if (segment.isSilent) {
        await _highlightSegment(segment);
        await Future.delayed(const Duration(milliseconds: 120));
        await getNextTextFunction();
        _currentSegment = null;
        audioToPlay = null;
        continue;
      }

      await audioPlayer.setVolume(volume);
      if (_shouldStop) return;

      final source = BytesSource(segment.audio!, mimeType: 'audio/mp3');
      Future<bool> playWith(AudioPlayer target, {required bool isRetry}) async {
        try {
          await target.play(source).timeout(const Duration(seconds: 10));
          return true;
        } on TimeoutException {
          await target.stop();
          return false;
        } catch (e) {
          await target.stop();
          return false;
        }
      }

      var played = await playWith(audioPlayer, isRetry: false);
      if (!played && !_shouldStop) {
        await _disposePlayer();
        if (_shouldStop) return;
        final retryPlayer = await _ensurePlayer();
        await retryPlayer.setVolume(volume);
        played = await playWith(retryPlayer, isRetry: true);
      }

      if (!played) {
        _currentSegment = null;
        audioToPlay = null;
        continue;
      }
      unawaited(_fillQueueIfNeeded(includeCurrent: false));
      return;
    }

    if (!_shouldStop) {
      updateTtsState(TtsStateEnum.stopped);
      await stop();
    }
  }

  Future<void> _onPlaybackComplete() async {
    if (_shouldStop) return;

    _currentSegment = null;
    audioToPlay = null;

    await getNextTextFunction();
    if (_shouldStop) return;

    await _playNextSegment();
  }

  @override
  Future<void> speak({String? content}) async {
    _shouldStop = false;
    await _ensurePlayer();

    await _syncWithLastLocation();

    if (_currentSegment == null && _segmentQueue.isEmpty) {
      // queue will be filled below
    }

    await _fillQueueIfNeeded(includeCurrent: true);
    await _playNextSegment();
  }

  @override
  Future<void> stop() async {
    _shouldStop = true;
    _needsLocationSync = true;
    _resetQueue();
    final pendingFill = _queueFillFuture;
    if (pendingFill != null) {
      try {
        await pendingFill;
      } catch (_) {}
    }
    _queueFillFuture = null;

    await _disposePlayer();
  }

  @override
  Future<void> pause() async {
    await player?.pause();
  }

  @override
  Future<void> resume() async {
    await player?.resume();
  }

  @override
  Future<void> prev() async {
    await stop();
    await getPrevTextFunction();
    _needsLocationSync = false;
    await speak();
  }

  @override
  Future<void> next() async {
    await stop();
    await getNextTextFunction();
    _needsLocationSync = false;
    await speak();
  }

  @override
  Future<void> restart() async {
    await stop();
    _needsLocationSync = false;
    await speak();
  }

  @override
  Future<void> dispose() async {
    await stop();
    isInit = false;
  }
}
