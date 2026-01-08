import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:anx_reader/utils/log/common.dart';

/// Native EPUB parser using pure Dart (archive + xml)
/// Replaces WebView/foliate-js for iOS 14 compatibility
class NativeEpubParser {
  final File file;
  late Archive _archive;
  late String _opfPath;
  late String _opfDir;

  // Parsed data
  String title = 'Unknown';
  String author = 'Unknown';
  List<EpubChapter> chapters = [];
  List<TocItem> toc = [];
  Map<String, String> manifest = {}; // id -> href
  List<String> spine = []; // ordered list of manifest ids

  NativeEpubParser(this.file);

  /// Initialize and parse the EPUB structure
  Future<void> parse() async {
    try {
      final bytes = await file.readAsBytes();
      _archive = ZipDecoder().decodeBytes(bytes);

      await _parseContainer();
      await _parseOpf();
      await _parseChapters();

      AnxLog.info(
          'NativeEpubParser: Parsed "$title" with ${chapters.length} chapters');
    } catch (e, s) {
      AnxLog.severe('NativeEpubParser: Failed to parse: $e', s);
      rethrow;
    }
  }

  /// Parse META-INF/container.xml to find OPF path
  Future<void> _parseContainer() async {
    final containerFile = _archive.findFile('META-INF/container.xml');
    if (containerFile == null) {
      throw Exception('Invalid EPUB: Missing container.xml');
    }

    final xml =
        XmlDocument.parse(utf8.decode(containerFile.content as List<int>));
    final rootfile = xml.findAllElements('rootfile').first;
    _opfPath = rootfile.getAttribute('full-path')!;
    _opfDir = _opfPath.contains('/')
        ? _opfPath.substring(0, _opfPath.lastIndexOf('/') + 1)
        : '';
  }

  /// Parse OPF file for metadata, manifest, and spine
  Future<void> _parseOpf() async {
    final opfFile = _archive.findFile(_opfPath);
    if (opfFile == null) {
      throw Exception('Invalid EPUB: Missing OPF at $_opfPath');
    }

    final xml = XmlDocument.parse(utf8.decode(opfFile.content as List<int>));

    // Parse metadata
    final metadata = xml.findAllElements('metadata').firstOrNull;
    if (metadata != null) {
      final titleEl = metadata.findAllElements('dc:title').firstOrNull ??
          metadata.findAllElements('title').firstOrNull;
      if (titleEl != null) title = titleEl.innerText.trim();

      final authorEl = metadata.findAllElements('dc:creator').firstOrNull ??
          metadata.findAllElements('creator').firstOrNull;
      if (authorEl != null) author = authorEl.innerText.trim();
    }

    // Parse manifest (id -> href mapping)
    final manifestEl = xml.findAllElements('manifest').firstOrNull;
    if (manifestEl != null) {
      for (final item in manifestEl.findAllElements('item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        if (id != null && href != null) {
          manifest[id] = href;
        }
      }
    }

    // Parse spine (reading order)
    final spineEl = xml.findAllElements('spine').firstOrNull;
    if (spineEl != null) {
      for (final itemref in spineEl.findAllElements('itemref')) {
        final idref = itemref.getAttribute('idref');
        if (idref != null) {
          spine.add(idref);
        }
      }
    }

    // Parse TOC from NCX or nav
    await _parseToc(xml);
  }

  /// Parse table of contents from NCX or nav document
  Future<void> _parseToc(XmlDocument opfXml) async {
    // Try to find NCX file
    String? ncxHref;
    final spineEl = opfXml.findAllElements('spine').firstOrNull;
    if (spineEl != null) {
      final tocId = spineEl.getAttribute('toc');
      if (tocId != null && manifest.containsKey(tocId)) {
        ncxHref = manifest[tocId];
      }
    }

    // Fallback: find NCX by media-type
    if (ncxHref == null) {
      final manifestEl = opfXml.findAllElements('manifest').firstOrNull;
      if (manifestEl != null) {
        for (final item in manifestEl.findAllElements('item')) {
          if (item.getAttribute('media-type') == 'application/x-dtbncx+xml') {
            ncxHref = item.getAttribute('href');
            break;
          }
        }
      }
    }

    if (ncxHref != null) {
      await _parseNcx(ncxHref);
    }
  }

  /// Parse NCX file for TOC
  Future<void> _parseNcx(String ncxHref) async {
    final ncxPath = _opfDir + ncxHref;
    final ncxFile = _archive.findFile(ncxPath);
    if (ncxFile == null) return;

    final xml = XmlDocument.parse(utf8.decode(ncxFile.content as List<int>));
    final navMap = xml.findAllElements('navMap').firstOrNull;
    if (navMap == null) return;

    toc = _parseNavPoints(navMap.findAllElements('navPoint'));
  }

  List<TocItem> _parseNavPoints(Iterable<XmlElement> navPoints) {
    return navPoints.map((np) {
      final label = np
              .findAllElements('navLabel')
              .firstOrNull
              ?.findAllElements('text')
              .firstOrNull
              ?.innerText
              .trim() ??
          '';
      final content = np.findAllElements('content').firstOrNull;
      final src = content?.getAttribute('src') ?? '';

      // Recursively parse nested nav points
      final children = _parseNavPoints(np.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'navPoint'));

      return TocItem(title: label, href: src, children: children);
    }).toList();
  }

  /// Parse chapters from spine
  Future<void> _parseChapters() async {
    for (int i = 0; i < spine.length; i++) {
      final id = spine[i];
      final href = manifest[id];
      if (href == null) continue;

      final chapterPath = _opfDir + href;
      final chapterFile = _archive.findFile(chapterPath);
      if (chapterFile == null) continue;

      String content;
      try {
        content = utf8.decode(chapterFile.content as List<int>);
      } catch (e) {
        // Try latin1 if utf8 fails
        content = latin1.decode(chapterFile.content as List<int>);
      }

      // Find chapter title from TOC or use filename
      String chapterTitle = 'Chapter ${i + 1}';
      for (final tocItem in toc) {
        if (tocItem.href.contains(href) ||
            href.contains(tocItem.href.split('#').first)) {
          chapterTitle = tocItem.title;
          break;
        }
      }

      chapters.add(EpubChapter(
        index: i,
        id: id,
        href: href,
        title: chapterTitle,
        htmlContent: content,
      ));
    }
  }

  /// Get chapter content by index
  EpubChapter? getChapter(int index) {
    if (index < 0 || index >= chapters.length) return null;
    return chapters[index];
  }

  /// Extract resource (images, css) by href
  /// Handles relative and absolute paths within EPUB
  List<int>? getResource(String href) {
    // Normalize path - remove leading ../ and ./
    String normalizedHref = href;
    while (normalizedHref.startsWith('../')) {
      normalizedHref = normalizedHref.substring(3);
    }
    while (normalizedHref.startsWith('./')) {
      normalizedHref = normalizedHref.substring(2);
    }

    // Try different path combinations
    final pathsToTry = [
      _opfDir + normalizedHref,
      normalizedHref,
      'OEBPS/' + normalizedHref,
      'OPS/' + normalizedHref,
    ];

    for (final path in pathsToTry) {
      final file = _archive.findFile(path);
      if (file != null) {
        return file.content as List<int>?;
      }
    }
    return null;
  }

  /// Get the base directory for a chapter (for resolving relative image paths)
  String getChapterDir(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return _opfDir;
    final chapter = chapters[chapterIndex];
    if (chapter.href.contains('/')) {
      return _opfDir +
          chapter.href.substring(0, chapter.href.lastIndexOf('/') + 1);
    }
    return _opfDir;
  }
}

/// Represents a single chapter
class EpubChapter {
  final int index;
  final String id;
  final String href;
  final String title;
  final String htmlContent;

  EpubChapter({
    required this.index,
    required this.id,
    required this.href,
    required this.title,
    required this.htmlContent,
  });
}

/// Table of contents item
class TocItem {
  final String title;
  final String href;
  final List<TocItem> children;

  TocItem({
    required this.title,
    required this.href,
    this.children = const [],
  });
}
