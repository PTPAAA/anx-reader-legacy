import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/native_epub_parser.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/utils/log/common.dart';

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
  final PageController _pageController = PageController();
  bool _showControls = false;

  // Expose methods for external control (matching EpubPlayer interface)
  String get chapterTitle => _parser?.chapters.isNotEmpty == true
      ? _parser!.chapters[_currentChapterIndex].title
      : '';
  double get percentage => _parser?.chapters.isEmpty != false
      ? 0.0
      : (_currentChapterIndex + 1) / _parser!.chapters.length;

  @override
  void initState() {
    super.initState();
    _loadBook();
  }

  Future<void> _loadBook() async {
    try {
      final file = File(widget.book.fileFullPath);
      _parser = NativeEpubParser(file);
      await _parser!.parse();

      // Restore reading position from CFI if available
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

  void _goToChapter(int index) {
    if (_parser == null) return;
    if (index < 0 || index >= _parser!.chapters.length) return;

    setState(() {
      _currentChapterIndex = index;
    });
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    // Reset scroll position for new chapter
    _scrollController.jumpTo(0);
  }

  void _nextChapter() {
    if (_parser == null) return;
    if (_currentChapterIndex < _parser!.chapters.length - 1) {
      _goToChapter(_currentChapterIndex + 1);
    }
  }

  void _prevChapter() {
    if (_currentChapterIndex > 0) {
      _goToChapter(_currentChapterIndex - 1);
    }
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    widget.showOrHideAppBarAndBottomBar(_showControls);
  }

  @override
  void dispose() {
    _saveProgress();
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('加载中...', style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
        ),
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
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
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
      return Center(
        child: Text('暂无内容', style: Theme.of(context).textTheme.bodyLarge),
      );
    }

    final prefs = Prefs();
    final theme = prefs.readTheme;
    final style = prefs.bookStyle;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Use theme colors, with dark mode fallback
    final bgColor = isDarkMode
        ? const Color(0xFF1A1A1A)
        : Color(int.parse('0xFF${theme.backgroundColor}'));
    final textColor = isDarkMode
        ? const Color(0xFFE0E0E0)
        : Color(int.parse('0xFF${theme.textColor}'));

    return Container(
      color: bgColor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          // Tap zones: left 1/4 = prev, right 1/4 = next, center = toggle controls
          final screenWidth = MediaQuery.of(context).size.width;
          final tapX = details.localPosition.dx;

          if (tapX < screenWidth * 0.25) {
            // Left zone - previous page/chapter
            if (_scrollController.hasClients &&
                _scrollController.offset > 100) {
              _scrollController.animateTo(
                _scrollController.offset -
                    MediaQuery.of(context).size.height * 0.8,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            } else {
              _prevChapter();
            }
          } else if (tapX > screenWidth * 0.75) {
            // Right zone - next page/chapter
            if (_scrollController.hasClients) {
              final maxScroll = _scrollController.position.maxScrollExtent;
              if (_scrollController.offset < maxScroll - 100) {
                _scrollController.animateTo(
                  _scrollController.offset +
                      MediaQuery.of(context).size.height * 0.8,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              } else {
                _nextChapter();
              }
            }
          } else {
            // Center zone - toggle controls
            _toggleControls();
          }
        },
        child: _buildChapterView(
            _parser!.chapters[_currentChapterIndex], bgColor, textColor, style),
      ),
    );
  }

  Widget _buildChapterView(
      EpubChapter chapter, Color bgColor, Color textColor, dynamic style) {
    // More readable font sizes
    final baseFontSize = (style.fontSize as num).toDouble();
    final actualFontSize = baseFontSize < 16 ? 18.0 : baseFontSize;
    final lineHeight = (style.lineHeight as num).toDouble();
    final actualLineHeight = lineHeight < 1.5 ? 1.6 : lineHeight;

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 16,
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Chapter title with better styling
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
                "h1": Style(
                  fontSize: FontSize(actualFontSize * 1.5),
                  fontWeight: FontWeight.bold,
                  color: textColor,
                  margin: Margins(top: Margin(16), bottom: Margin(16)),
                ),
                "h2": Style(
                  fontSize: FontSize(actualFontSize * 1.3),
                  fontWeight: FontWeight.bold,
                  color: textColor,
                  margin: Margins(top: Margin(14), bottom: Margin(14)),
                ),
                "h3": Style(
                  fontSize: FontSize(actualFontSize * 1.1),
                  fontWeight: FontWeight.w600,
                  color: textColor,
                  margin: Margins(top: Margin(12), bottom: Margin(12)),
                ),
                "img": Style(
                  width: Width(MediaQuery.of(context).size.width - 40),
                  margin: Margins(top: Margin(16), bottom: Margin(16)),
                ),
                "a": Style(
                  color: Theme.of(context).colorScheme.primary,
                  textDecoration: TextDecoration.underline,
                ),
              },
              onLinkTap: (url, _, __) {
                if (url != null && !url.startsWith('http')) {
                  final chapterIndex = _parser!.chapters.indexWhere((c) =>
                      url.contains(c.href) ||
                      c.href.contains(url.split('#').first));
                  if (chapterIndex >= 0) {
                    _goToChapter(chapterIndex);
                  }
                }
              },
            ),
            // Bottom navigation
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  // Progress indicator
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: textColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${_currentChapterIndex + 1} / ${_parser!.chapters.length}',
                            style: TextStyle(
                              color: textColor.withOpacity(0.7),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Navigation buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (_currentChapterIndex > 0)
                        TextButton.icon(
                          onPressed: _prevChapter,
                          icon: Icon(Icons.arrow_back_ios,
                              color: textColor.withOpacity(0.7), size: 18),
                          label: Text('上一章',
                              style:
                                  TextStyle(color: textColor.withOpacity(0.7))),
                        )
                      else
                        const SizedBox(width: 100),
                      if (_currentChapterIndex < _parser!.chapters.length - 1)
                        TextButton.icon(
                          onPressed: _nextChapter,
                          icon: Icon(Icons.arrow_forward_ios,
                              color: textColor.withOpacity(0.7), size: 18),
                          label: Text('下一章',
                              style:
                                  TextStyle(color: textColor.withOpacity(0.7))),
                        )
                      else
                        const SizedBox(width: 100),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Clean up HTML for better rendering
  String _preprocessHtml(String html) {
    // Remove XML declarations and doctype
    var cleaned = html
        .replaceAll(RegExp(r'<\?xml[^>]*\?>'), '')
        .replaceAll(RegExp(r'<!DOCTYPE[^>]*>'), '')
        .replaceAll(RegExp(r'<html[^>]*>'), '<div>')
        .replaceAll(RegExp(r'</html>'), '</div>')
        .replaceAll(RegExp(r'<head>.*?</head>', dotAll: true), '')
        .replaceAll(RegExp(r'<body[^>]*>'), '')
        .replaceAll(RegExp(r'</body>'), '');
    return cleaned;
  }
}
