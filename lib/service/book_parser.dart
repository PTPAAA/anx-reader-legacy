import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:anx_reader/utils/log/common.dart';

/// Manual EPUB parser using archive + xml packages
/// This avoids dependency conflicts with epub packages that require specific image versions
class BookParser {
  /// Parse EPUB file metadata manually
  static Future<Map<String, dynamic>> parseEpubMetadata(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Step 1: Read container.xml to find OPF path
      final containerFile = archive.findFile('META-INF/container.xml');
      if (containerFile == null) {
        throw Exception('Invalid EPUB: Missing META-INF/container.xml');
      }

      final containerXml = XmlDocument.parse(
        utf8.decode(containerFile.content as List<int>),
      );
      final rootfileElement = containerXml.findAllElements('rootfile').first;
      final opfPath = rootfileElement.getAttribute('full-path');
      if (opfPath == null) {
        throw Exception('Invalid EPUB: No OPF path in container.xml');
      }

      // Step 2: Read OPF file for metadata
      final opfFile = archive.findFile(opfPath);
      if (opfFile == null) {
        throw Exception('Invalid EPUB: Missing OPF file at $opfPath');
      }

      final opfXml = XmlDocument.parse(
        utf8.decode(opfFile.content as List<int>),
      );

      // Extract metadata from OPF
      final metadataElement = opfXml.findAllElements('metadata').firstOrNull ??
          opfXml.findAllElements('dc:metadata').firstOrNull;

      String title = 'Unknown';
      String author = 'Unknown';
      String? description;
      String? coverPath;

      if (metadataElement != null) {
        // Title (dc:title)
        final titleEl =
            metadataElement.findAllElements('dc:title').firstOrNull ??
                metadataElement.findAllElements('title').firstOrNull;
        if (titleEl != null) {
          title = titleEl.innerText.trim();
        }

        // Author (dc:creator)
        final authorEl =
            metadataElement.findAllElements('dc:creator').firstOrNull ??
                metadataElement.findAllElements('creator').firstOrNull;
        if (authorEl != null) {
          author = authorEl.innerText.trim();
        }

        // Description (dc:description)
        final descEl =
            metadataElement.findAllElements('dc:description').firstOrNull ??
                metadataElement.findAllElements('description').firstOrNull;
        if (descEl != null) {
          description = descEl.innerText.trim();
        }

        // Cover image - find meta with name="cover"
        final coverMeta = metadataElement
            .findAllElements('meta')
            .where((e) => e.getAttribute('name') == 'cover')
            .firstOrNull;
        if (coverMeta != null) {
          final coverId = coverMeta.getAttribute('content');
          if (coverId != null) {
            // Find manifest item with this ID
            final manifestElement =
                opfXml.findAllElements('manifest').firstOrNull;
            if (manifestElement != null) {
              final coverItem = manifestElement
                  .findAllElements('item')
                  .where((e) => e.getAttribute('id') == coverId)
                  .firstOrNull;
              if (coverItem != null) {
                coverPath = coverItem.getAttribute('href');
              }
            }
          }
        }
      }

      // Step 3: Extract cover image if found
      String coverBase64 = '';
      if (coverPath != null) {
        // Resolve cover path relative to OPF
        final opfDir = opfPath.contains('/')
            ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
            : '';
        final fullCoverPath = opfDir + coverPath;

        final coverFile = archive.findFile(fullCoverPath);
        if (coverFile != null) {
          final coverBytes = coverFile.content as List<int>;
          final mimeType =
              coverPath.endsWith('.png') ? 'image/png' : 'image/jpeg';
          coverBase64 = 'data:$mimeType;base64,${base64Encode(coverBytes)}';
        }
      }

      AnxLog.info('BookParser: Parsed "$title" by $author');

      return {
        'title': title,
        'author': author,
        'description': description ?? '',
        'cover': coverBase64,
      };
    } catch (e, s) {
      AnxLog.severe('BookParser: Failed to parse epub: $e', s);
      rethrow;
    }
  }
}
