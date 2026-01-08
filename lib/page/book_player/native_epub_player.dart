import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/native_epub_parser.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:intl/intl.dart';

/// Bookmark model for native reader
class NativeBookmark {
  final String id;
  final int chapterIndex;
  final double scrollPosition;
  final String label;
  final DateTime createdAt;

  NativeBookmark({
    required this.id,
    required this.chapterIndex,
    required this.scrollPosition,
    required this.label,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'chapterIndex': chapterIndex,
        'scrollPosition': scrollPosition,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
      };

  factory NativeBookmark.fromJson(Map<String, dynamic> json) => NativeBookmark(
        id: json['id'],
        chapterIndex: json['chapterIndex'],
        scrollPosition: json['scrollPosition'],
        label: json['label'],
        createdAt: DateTime.parse(json['createdAt']),
      );
}

/// Native EPUB reader widget for iOS 14 compatibility
class NativeEpubPlayer extends ConsumerStatefulWidget {
  final Book book;
  final String? cfi;
  final Function(bool) showOrHideAppBarAndBottomBar;
  final Function onLoadEnd;

  const NativeEpubPlayer({
    super.key,
    required this.book,
    this.cfi,
    required this.showOrHideAppBarAndBottomBar,
    required this.onLoadEnd,
  });

  @override
  ConsumerState<NativeEpubPlayer> createState() => NativeEpubPlayerState();
}

class NativeEpubPlayerState extends ConsumerState<NativeEpubPlayer> {
  NativeEpubParser? _parser;
  bool _isLoading = true;
  String? _error;
  int _currentChapterIndex = 0;
  final ScrollController _scrollController = ScrollController();
  bool _showControls = false;

  // Cached HTML for performance
  final Map<int, String> _processedHtmlCache = {};

  // Status bar
  int _batteryLevel = 100;
  String _currentTime = '';
  Timer? _statusTimer;
  double _chapterScrollProgress = 0.0;

  // Bookmarks - use ValueNotifier for reactive updates
  final ValueNotifier<List<NativeBookmark>> _bookmarksNotifier =
      ValueNotifier([]);

  // Expose for reading_page
  NativeEpubParser? get parser => _parser;
  String get chapterTitle => _parser?.chapters.isNotEmpty == true
      ? _parser!.chapters[_currentChapterIndex].title
      : '';
  double get percentage => _parser?.chapters.isEmpty != false
      ? 0.0
      : (_currentChapterIndex + 1) / _parser!.chapters.length;
  int get currentChapterIndex => _currentChapterIndex;
  List<TocItem> get toc => _parser?.toc ?? [];
  List<NativeBookmark> get bookmarks => _bookmarksNotifier.value;
  ValueNotifier<List<NativeBookmark>> get bookmarksNotifier =>
      _bookmarksNotifier;

  @override
  void initState() {
    super.initState();
    _loadBook();
    _startStatusUpdates();
    _scrollController.addListener(_onScroll);
  }

  void _startStatusUpdates() {
    _updateStatus();
    _statusTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _updateStatus());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _scrollController.dispose();
    _bookmarksNotifier.dispose();
    super.dispose();
  }

  Future<void> _updateStatus() async {
    try {
      final level = await Battery().batteryLevel;
      if (mounted) {
        setState(() {
          _batteryLevel = level;
          _currentTime = DateFormat('HH:mm').format(DateTime.now());
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
            () => _currentTime = DateFormat('HH:mm').format(DateTime.now()));
      }
    }
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll > 0) {
        final progress = _scrollController.offset / maxScroll;
        if ((progress - _chapterScrollProgress).abs() > 0.01) {
          setState(() => _chapterScrollProgress = progress);
        }
      }
    }
  }

  Future<void> _loadBook() async {
    try {
      final file = File(widget.book.fileFullPath);
      _parser = NativeEpubParser(file);
      await _parser!.parse();
      await _loadBookmarks();

      final cfi = widget.cfi ?? widget.book.lastReadPosition;
      if (cfi.isNotEmpty) {
        _currentChapterIndex = _parseChapterFromCfi(cfi);
      }

      setState(() => _isLoading = false);
      widget.onLoadEnd();
      _updateProgress();
    } catch (e) {
      AnxLog.severe('NativeEpubPlayer: Failed to load book: $e');
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> saveProgress() async {
    await _updateProgress();
  }

  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'bookmarks_${widget.book.id}';
    final data = prefs.getString(key);
    if (data != null) {
      final list = jsonDecode(data) as List;
      _bookmarksNotifier.value =
          list.map((e) => NativeBookmark.fromJson(e)).toList();
    }
  }

  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'bookmarks_${widget.book.id}';
    await prefs.setString(key,
        jsonEncode(_bookmarksNotifier.value.map((e) => e.toJson()).toList()));
  }

  void addBookmark() {
    final progress = (percentage * 100).toStringAsFixed(0);
    final now = DateTime.now();
    final label = '${now.year % 100}.${now.month}.${now.day}-$progress%';

    final bookmark = NativeBookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      chapterIndex: _currentChapterIndex,
      scrollPosition:
          _scrollController.hasClients ? _scrollController.offset : 0,
      label: label,
      createdAt: now,
    );

    // Use ValueNotifier for reactive updates (no setState needed)
    _bookmarksNotifier.value = [..._bookmarksNotifier.value, bookmark];
    _saveBookmarks();
  }

  void goToBookmark(NativeBookmark bookmark) {
    goToChapter(bookmark.chapterIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(bookmark.scrollPosition);
      }
    });
  }

  void deleteBookmark(String id) {
    // Use ValueNotifier for reactive updates (no setState needed)
    _bookmarksNotifier.value =
        _bookmarksNotifier.value.where((b) => b.id != id).toList();
    _saveBookmarks();
  }

  int _parseChapterFromCfi(String cfi) {
    try {
      final match = RegExp(r'/6/(\d+)').firstMatch(cfi);
      if (match != null) {
        return (int.parse(match.group(1)!) ~/ 2) - 1;
      }
    } catch (e) {}
    return 0;
  }

  String _generateCfi() => 'epubcfi(/6/${(_currentChapterIndex + 1) * 2})';

  Future<void> _updateProgress() async {
    if (_parser == null) return;

    final cfi = _generateCfi();
    final pct = _parser!.chapters.isEmpty
        ? 0.0
        : (_currentChapterIndex + 1) / _parser!.chapters.length;

    Book book = widget.book;
    book.lastReadPosition = cfi;
    book.readingPercentage = pct;
    await bookDao.updateBook(book);

    if (mounted) {
      ref.read(bookListProvider.notifier).refresh();
    }
  }

  void goToChapter(int index) {
    if (_parser == null || index < 0 || index >= _parser!.chapters.length)
      return;

    setState(() {
      _currentChapterIndex = index;
      _chapterScrollProgress = 0;
    });
    _scrollController.jumpTo(0);
    _updateProgress();
  }

  void _scrollPage(bool forward) {
    if (!_scrollController.hasClients) return;

    final pageHeight = MediaQuery.of(context).size.height * 0.85;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;

    if (forward) {
      if (offset >= maxScroll - 10) {
        if (_currentChapterIndex < _parser!.chapters.length - 1) {
          goToChapter(_currentChapterIndex + 1);
        }
      } else {
        _scrollController.animateTo(
          (offset + pageHeight).clamp(0, maxScroll),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    } else {
      if (offset <= 10) {
        if (_currentChapterIndex > 0) {
          goToChapter(_currentChapterIndex - 1);
        }
      } else {
        _scrollController.animateTo(
          (offset - pageHeight).clamp(0, maxScroll),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void _toggleControls() {
    // No need for setState - _showControls is only used by parent widget
    _showControls = !_showControls;
    widget.showOrHideAppBarAndBottomBar(_showControls);
  }

  @override
  void dispose() {
    _updateProgress();
    _scrollController.dispose();
    _statusTimer?.cancel();
    _bookmarksNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('加载失败', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    return _buildReaderView();
  }

  Widget _buildReaderView() {
    if (_parser == null || _parser!.chapters.isEmpty) {
      return const Center(child: Text('暂无内容'));
    }

    final prefs = Prefs();
    final style = prefs.bookStyle;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFFAF8F5);
    final textColor =
        isDark ? const Color(0xFFE0E0E0) : const Color(0xFF333333);

    return Container(
      color: bgColor,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _handleTap(d, MediaQuery.of(context).size),
              child: _buildChapterView(bgColor, textColor, style),
            ),
          ),
          _buildStatusBar(bgColor, textColor),
        ],
      ),
    );
  }

  void _handleTap(TapUpDetails d, Size size) {
    final x = d.localPosition.dx;
    final y = d.localPosition.dy;

    // Bottom corners for page turn
    if (y > size.height * 0.7) {
      if (x < size.width * 0.3)
        _scrollPage(false);
      else if (x > size.width * 0.7)
        _scrollPage(true);
      else
        _toggleControls();
    }
    // Side areas
    else if (x < size.width * 0.25)
      _scrollPage(false);
    else if (x > size.width * 0.75)
      _scrollPage(true);
    else
      _toggleControls();
  }

  Widget _buildStatusBar(Color bg, Color text) {
    final muted = text.withOpacity(0.5);
    final progress = _parser!.chapters.isEmpty
        ? 0.0
        : (_currentChapterIndex + _chapterScrollProgress) /
            _parser!.chapters.length;

    return Container(
      color: bg,
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).padding.bottom + 6,
        top: 6,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            Icon(Icons.battery_std, size: 14, color: muted),
            const SizedBox(width: 4),
            Text('$_batteryLevel%',
                style: TextStyle(fontSize: 11, color: muted)),
          ]),
          Text(
            '${_currentChapterIndex + 1}/${_parser!.chapters.length} · ${(progress * 100).toStringAsFixed(0)}%',
            style: TextStyle(fontSize: 11, color: muted),
          ),
          Text(_currentTime, style: TextStyle(fontSize: 11, color: muted)),
        ],
      ),
    );
  }

  Widget _buildChapterView(Color bg, Color text, dynamic style) {
    final chapter = _parser!.chapters[_currentChapterIndex];

    // BookStyle stores fontSize as multiplier (1.0 = 16px, 1.4 = 22px)
    // lineHeight and sideMargin are stored as their actual values
    final fontMult =
        ((style.fontSize as num?) ?? 1.4).toDouble().clamp(0.8, 2.5);
    final fontSize = fontMult * 16; // Convert multiplier to pixels
    final lineHeight =
        ((style.lineHeight as num?) ?? 1.6).toDouble().clamp(1.2, 2.5);
    final margin =
        ((style.sideMargin as num?) ?? 20).toDouble().clamp(8.0, 40.0);

    // Use cached HTML
    final html = _processedHtmlCache[_currentChapterIndex] ??=
        _preprocessHtml(chapter.htmlContent);

    return RepaintBoundary(
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: margin, vertical: 16),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Chapter title
              Padding(
                padding: const EdgeInsets.only(bottom: 20, top: 8),
                child: Text(
                  chapter.title,
                  style: TextStyle(
                    fontSize: fontSize + 4,
                    fontWeight: FontWeight.w600,
                    color: text,
                    height: 1.3,
                  ),
                ),
              ),
              // Content
              Html(
                data: html,
                style: {
                  "*": Style(
                    fontSize: FontSize(fontSize),
                    color: text,
                    lineHeight: LineHeight(lineHeight),
                    margin: Margins.zero,
                    padding: HtmlPaddings.zero,
                  ),
                  "p": Style(
                    margin: Margins(bottom: Margin(fontSize * 0.7)),
                  ),
                  "img": Style(
                    width:
                        Width(MediaQuery.of(context).size.width - margin * 2),
                  ),
                },
                extensions: [
                  ImageExtension(
                    builder: (ctx) => _buildImage(ctx.attributes['src'] ?? ''),
                  ),
                ],
                onLinkTap: (url, _, __) {
                  if (url != null && !url.startsWith('http')) {
                    final idx = _parser!.chapters.indexWhere((c) =>
                        url.contains(c.href) ||
                        c.href.contains(url.split('#').first));
                    if (idx >= 0) goToChapter(idx);
                  }
                },
              ),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage(String src) {
    if (src.isEmpty) return const SizedBox.shrink();

    // Get the current chapter's directory for resolving relative paths
    final chapterDir = _parser?.getChapterDir(_currentChapterIndex) ?? '';

    // Try to load from EPUB archive with chapter directory context
    final imageData = _parser?.getResource(src, baseDir: chapterDir);
    if (imageData != null) {
      return Image.memory(
        Uint8List.fromList(imageData),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return const SizedBox.shrink();
  }

  String _preprocessHtml(String html) {
    return html
        .replaceAll(RegExp(r'<\?xml[^>]*\?>'), '')
        .replaceAll(RegExp(r'<!DOCTYPE[^>]*>'), '')
        .replaceAll(RegExp(r'<html[^>]*>'), '')
        .replaceAll(RegExp(r'</html>'), '')
        .replaceAll(RegExp(r'<head>.*?</head>', dotAll: true), '')
        .replaceAll(RegExp(r'<body[^>]*>'), '')
        .replaceAll(RegExp(r'</body>'), '');
  }
}
