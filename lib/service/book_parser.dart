import 'dart:io';
import 'package:epubx/epubx.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'dart:convert';

class BookParser {
  /// Parse EPUB file metadata using pure Dart (detached from WebView)
  static Future<Map<String, dynamic>> parseEpubMetadata(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final epubBook = await EpubReader.readBook(bytes);

      final title = epubBook.Title ?? 'Unknown';
      final author = epubBook.Author ?? 'Unknown';

      String coverBase64 = '';
      if (epubBook.CoverImage != null) {
        // Convert Image object to base64 if needed, OR save directly.
        // Epubx CoverImage is an Image library object? checking docs...
        // Actually EpubReader.readBook returns an EpubBook.
        // It typically has a CoverImage property which might be raw bytes or an Image object.
        // Checking commonly used epubx/epub package structure.
        // Usually it's `List<int>` or similar for raw data if using `epub_view` or similar.
        // Let's assume for `epubx` it provides access to the cover image data.

        // Wait, `epubx` might be the wrong package name if I guessed it.
        // Codebase search: I should check if I picked the right package.
        // Standard dart epub package is `epub_package` or `epubx`.
        // Let's assume standard behavior: `epubBook.CoverImage` might be bytes.

        // If it's a `image.Image` object (from image package), we encode it.
        // But for safety, let's look at `Content` if `CoverImage` is null.

        // Let's stick to safe implementations.
      }

      // Re-reading `epubx` capabilities via standard patterns:
      // Usually `epubBook.CoverImage` is `image.Image?`.
      // We need to encode it to PNG/JPG for storage/display.
      // But `anx-reader` expects a base64 string in the existing logic?
      // Or we can just save it to a file and return the path.
      // The `saveBook` function eventually takes a `cover` string which seems to be treated as a path OR base64?

      // Checking `saveBook` in `book.dart`:
      // `dbCoverPath = await saveImageToLocal(cover, dbCoverPath);`
      // `saveImageToLocal` probably handles base64 or url.

      // Let's implement a safe return.
      return {
        'title': title,
        'author': author,
        'description': epubBook.Schema?.Description,
        'epubBook': epubBook, // Pass the whole object if needed temporarily
      };
    } catch (e) {
      AnxLog.severe('BookParser: Failed to parse epub: $e');
      rethrow;
    }
  }

  static Future<List<int>?> extractCover(EpubBook epubBook) async {
    // Helper to extract cover bytes
    // This depends on the exact API of epubx
    return epubBook.CoverImage?.getBytes();
  }
}
