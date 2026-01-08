import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:anx_reader/utils/log/common.dart';

/// Prepares the local environment for iOS 14 support by copying necessary assets
/// to the Documents directory. This allows file:// access to work without CSP/Origin issues.
Future<String> prepareLocalPlayer() async {
  try {
    final docDir = await getApplicationDocumentsDirectory();
    final foliateDir = Directory(p.join(docDir.path, 'foliate-js'));
    final distDir = Directory(p.join(foliateDir.path, 'dist'));

    if (!distDir.existsSync()) {
      distDir.createSync(recursive: true);
    }

    // 1. Write Modified index.html (Force Legacy Bundle)
    final indexHtmlFile = File(p.join(foliateDir.path, 'index.html'));

    // Read original index.html to preserve styles/structure, but we need to patch the script.
    // Since reading assets as string is async, we do it here.
    String indexContent =
        await rootBundle.loadString('assets/foliate-js/index.html');

    // No longer patching shouldUseModernBundle - let original detection logic work
    // The iOS WebView should correctly detect as Apple device and use modern bundle

    await indexHtmlFile.writeAsString(indexContent);

    // 2. Copy Dist Files
    final filesToCopy = [
      'bundle.js',
      'pdf-legacy.js',
      'pdf-legacy.worker.js',
    ];

    for (final filename in filesToCopy) {
      final targetFile = File(p.join(distDir.path, filename));
      // Optimization: Check existence/size? For now, overwrite to ensure update.
      // But large files copying repeatedly is slow.
      // check if exists.
      if (!targetFile.existsSync()) {
        final data = await rootBundle.load('assets/foliate-js/dist/$filename');
        await targetFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    }

    AnxLog.info('Local Player prepared locally at: ${foliateDir.path}');
    return indexHtmlFile.path;
  } catch (e) {
    AnxLog.severe('Failed to prepare local player: $e');
    rethrow;
  }
}
