import 'dart:typed_data';

import 'package:anx_reader/service/tts/models/tts_sentence.dart';

class TtsSegment {
  TtsSegment({required this.sentence});

  final TtsSentence sentence;
  Uint8List? audio;
  bool isSilent = false;

  bool get isReady => isSilent || (audio != null && audio!.isNotEmpty);
}
