import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_audio/return_code.dart';

static Future<String> compressIfNeeded(String audioPath) async {
  final file = File(audioPath);
  final sizeInMB = await file.length() / (1024 * 1024);
  
  if (sizeInMB <= 24) {
    debugPrint('[Compressor] File is ${sizeInMB.toStringAsFixed(1)}MB — no compression needed');
    return audioPath; // send as is
  }

  debugPrint('[Compressor] File is ${sizeInMB.toStringAsFixed(1)}MB — compressing...');
  
  final compressedPath = audioPath.replaceAll('.mp3', '_compressed.mp3')
                                   .replaceAll('.m4a', '_compressed.m4a');

  // Target 64kbps — good for speech, keeps file small
  final session = await FFmpegKit.execute(
    '-i "$audioPath" -b:a 64k -y "$compressedPath"'
  );

  final returnCode = await session.getReturnCode();
  
  if (ReturnCode.isSuccess(returnCode)) {
    final newSize = File(compressedPath).lengthSync() / (1024 * 1024);
    debugPrint('[Compressor] Compressed to ${newSize.toStringAsFixed(1)}MB');
    return compressedPath;
  } else {
    debugPrint('[Compressor] Compression failed — sending original');
    return audioPath; // fallback to original
  }
}