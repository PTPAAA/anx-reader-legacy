import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/native_epub_parser.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:intl/intl.dart';

/// Native EPUB reader widget for iOS 14 compatibility
/// Uses flutter_html instead of WebView/foliate-js
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

  // Status bar info
  int _batteryLevel = 100;
  String _currentTime = '';
  Timer? _statusTimer;
  double _chapterScrollProgress = 0.0;

  // Expose for reading_page integration
  NativeEpubParser? get parser => _parser;
  String get chapterTitle => _parser?.chapters.isNotEmpty == true
      ? _parser!.chapters[_currentChapterIndex].title
      : '';
  double get percentage => _parser?.chapters.isEmpty != false
      ? 0.0
      : (_currentChapterIndex + 1) / _parser!.chapters.length;
  int get currentChapterIndex => _currentChapterIndex;
  List<TocItem> get toc => _parser?.toc ?? [];

  @override
  void initState() {
    super.initState();
    _loadBook();
    _startStatusUpdates();
    _scrollController.addListener(_onScroll);
  }

  void _startStatusUpdates() {
    _updateStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _updateStatus();
    });
  }

  Future<void> _updateStatus() async {
    try {
      final battery = Battery();
      final level = await battery.batteryLevel;
      if (mounted) {
        setState(() {
          _batteryLevel = level;
          _currentTime = DateFormat('HH:mm').format(DateTime.now());
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _currentTime = DateFormat('HH:mm').format(DateTime.now());
        });
      }
    }
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll > 0) {
        setState(() {
          _chapterScrollProgress = _scrollController.offset / maxScroll;
        });
      }
    }
  }

  Future<void> _loadBook() async {
    try {
      final file = File(widget.book.fileFullPath);
      _parser = NativeEpubParser(file);
      await _parser!.parse();

      final cfi = widget.cfi ?? widget.book.lastReadPosition;
      if (cfi.isNotEmpty) {
        _currentChapterIndex = _parseChapterFromCfi(cfi);
      }

      setState(() {
        _isLoading = false;
      });

      widget.onLoadEnd();
    } catch (e) {
      AnxLog.severe('NativeEpubPlayer: Failed to load book: $e');
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  int _parseChapterFromCfi(String cfi) {
    try {
      final match = RegExp(r'/6/(\d+)').firstMatch(cfi);
      if (match != null) {
        final chapterNum = int.parse(match.group(1)!);
        return (chapterNum ~/ 2) - 1;
      }
    } catch (e) {
      AnxLog.warning('NativeEpubPlayer: Failed to parse CFI: $cfi');
    }
    return 0;
  }

  String _generateCfi() {
    final chapterNum = (_currentChapterIndex + 1) * 2;
    return 'epubcfi(/6/$chapterNum)';
  }

  Future<void> _saveProgress() async {
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
    if (_parser == null) return;
    if (index < 0 || index >= _parser!.chapters.length) return;

    setState(() {
      _currentChapterIndex = index;
      _chapterScrollProgress = 0;
    });
    _scrollController.jumpTo(0);
  }

  void _nextChapter() {
    if (_parser == null) return;
    if (_currentChapterIndex < _parser!.chapters.length - 1) {
      goToChapter(_currentChapterIndex + 1);
    }
  }

  void _prevChapter() {
    if (_currentChapterIndex > 0) {
      goToChapter(_currentChapterIndex - 1);
    }
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    widget.showOrHideAppBarAndBottomBar(_showControls);
  }

  void _scrollPage(bool forward) {
    if (!_scrollController.hasClients) return;

    final pageHeight = MediaQuery.of(context).size.height * 0.85;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentOffset = _scrollController.offset;

    if (forward) {
      if (currentOffset >= maxScroll - 10) {
        _nextChapter();
      } else {
        _scrollController.animateTo(
          (currentOffset + pageHeight).clamp(0, maxScroll),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    } else {
      if (currentOffset <= 10) {
        _prevChapter();
      } else {
        _scrollController.animateTo(
          (currentOffset - pageHeight).clamp(0, maxScroll),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  void dispose() {
    _saveProgress();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _statusTimer?.cancel();
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
              Icon(Icons.error_outline,
                  size: 64, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text('加载失败', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回'),
              ),
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
    final theme = prefs.readTheme;
    final style = prefs.bookStyle;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isDarkMode
        ? const Color(0xFF1A1A1A)
        : Color(int.parse('0xFF${theme.backgroundColor}'));
    final textColor = isDarkMode
        ? const Color(0xFFE0E0E0)
        : Color(int.parse('0xFF${theme.textColor}'));

    return Container(
      color: bgColor,
      child: Column(
        children: [
          // Main content area with tap zones
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                final size = MediaQuery.of(context).size;
                final tapX = details.localPosition.dx;
                final tapY = details.localPosition.dy;

                // Bottom corners for page turning
                if (tapY > size.height * 0.7) {
                  if (tapX < size.width * 0.3) {
                    _scrollPage(false); // prev
                  } else if (tapX > size.width * 0.7) {
                    _scrollPage(true); // next
                  } else {
                    _toggleControls();
                  }
                }
                // Middle area for controls
                else if (tapY > size.height * 0.3) {
                  if (tapX > size.width * 0.25 && tapX < size.width * 0.75) {
                    _toggleControls();
                  } else if (tapX < size.width * 0.25) {
                    _scrollPage(false);
                  } else {
                    _scrollPage(true);
                  }
                }
                // Top area
                else {
                  if (tapX < size.width * 0.3) {
                    _scrollPage(false);
                  } else if (tapX > size.width * 0.7) {
                    _scrollPage(true);
                  } else {
                    _toggleControls();
                  }
                }
              },
              child: _buildChapterView(
                _parser!.chapters[_currentChapterIndex],
                bgColor,
                textColor,
                style,
              ),
            ),
          ),
          // Status bar
          _buildStatusBar(bgColor, textColor),
        ],
      ),
    );
  }

  Widget _buildStatusBar(Color bgColor, Color textColor) {
    final mutedColor = textColor.withOpacity(0.5);
    final chapterProgress = _parser!.chapters.isEmpty
        ? 0.0
        : (_currentChapterIndex + _chapterScrollProgress) /
            _parser!.chapters.length;

    return Container(
      color: bgColor,
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).padding.bottom + 8,
        top: 8,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Battery
          Row(
            children: [
              Icon(
                _batteryLevel > 80
                    ? Icons.battery_full
                    : _batteryLevel > 50
                        ? Icons.battery_5_bar
                        : _batteryLevel > 20
                            ? Icons.battery_3_bar
                            : Icons.battery_1_bar,
                size: 16,
                color: mutedColor,
              ),
              const SizedBox(width: 4),
              Text(
                '$_batteryLevel%',
                style: TextStyle(fontSize: 12, color: mutedColor),
              ),
            ],
          ),
          // Chapter progress
          Text(
            '${_currentChapterIndex + 1}/${_parser!.chapters.length} · ${(chapterProgress * 100).toStringAsFixed(1)}%',
            style: TextStyle(fontSize: 12, color: mutedColor),
          ),
          // Time
          Text(
            _currentTime,
            style: TextStyle(fontSize: 12, color: mutedColor),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterView(
      EpubChapter chapter, Color bgColor, Color textColor, dynamic style) {
    final baseFontSize = (style.fontSize as num).toDouble();
    final actualFontSize = baseFontSize < 16 ? 18.0 : baseFontSize;
    final lineHeight = (style.lineHeight as num).toDouble();
    final actualLineHeight = lineHeight < 1.5 ? 1.6 : lineHeight;
    final sideMargin = (style.sideMargin as num).toDouble();

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.symmetric(
        horizontal: sideMargin > 0 ? sideMargin : 20,
        vertical: 16,
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Chapter title
            Container(
              padding: const EdgeInsets.only(bottom: 24, top: 8),
              child: Text(
                chapter.title,
                style: TextStyle(
                  fontSize: actualFontSize + 6,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                  height: 1.3,
                ),
              ),
            ),
            // Chapter content
            Html(
              data: _preprocessHtml(chapter.htmlContent),
              style: {
                "body": Style(
                  fontSize: FontSize(actualFontSize),
                  color: textColor,
                  lineHeight: LineHeight(actualLineHeight),
                  textAlign: TextAlign.justify,
                  padding: HtmlPaddings.zero,
                  margin: Margins.zero,
                ),
                "p": Style(
                  fontSize: FontSize(actualFontSize),
                  color: textColor,
                  lineHeight: LineHeight(actualLineHeight),
                  margin: Margins(bottom: Margin(actualFontSize * 0.8)),
                ),
                "h1, h2, h3": Style(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                  margin: Margins(top: Margin(16), bottom: Margin(12)),
                ),
                "img": Style(
                  width: Width(
                      MediaQuery.of(context).size.width - sideMargin * 2 - 40),
                  margin: Margins(top: Margin(16), bottom: Margin(16)),
                ),
                "a": Style(
                  color: Theme.of(context).colorScheme.primary,
                ),
              },
              onLinkTap: (url, _, __) {
                if (url != null && !url.startsWith('http')) {
                  final chapterIndex = _parser!.chapters.indexWhere((c) =>
                      url.contains(c.href) ||
                      c.href.contains(url.split('#').first));
                  if (chapterIndex >= 0) {
                    goToChapter(chapterIndex);
                  }
                }
              },
            ),
            // Bottom padding for comfortable reading
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  String _preprocessHtml(String html) {
    return html
        .replaceAll(RegExp(r'<\?xml[^>]*\?>'), '')
        .replaceAll(RegExp(r'<!DOCTYPE[^>]*>'), '')
        .replaceAll(RegExp(r'<html[^>]*>'), '<div>')
        .replaceAll(RegExp(r'</html>'), '</div>')
        .replaceAll(RegExp(r'<head>.*?</head>', dotAll: true), '')
        .replaceAll(RegExp(r'<body[^>]*>'), '')
        .replaceAll(RegExp(r'</body>'), '');
  }
}
