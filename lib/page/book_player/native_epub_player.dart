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
  final Function showOrHideAppBarAndBottomBar;
  final Function onLoadEnd;

  const NativeEpubPlayer({
    super.key,
    required this.book,
    this.cfi,
    required this.showOrHideAppBarAndBottomBar,
    required this.onLoadEnd,
  });

  @override
  ConsumerState<NativeEpubPlayer> createState() => _NativeEpubPlayerState();
}

class _NativeEpubPlayerState extends ConsumerState<NativeEpubPlayer> {
  NativeEpubParser? _parser;
  bool _isLoading = true;
  String? _error;
  int _currentChapterIndex = 0;
  final ScrollController _scrollController = ScrollController();
  final PageController _pageController = PageController();

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
    // CFI format: epubcfi(/6/N[...]!...) where N indicates chapter
    // Simplified parsing - extract chapter index
    try {
      final match = RegExp(r'/6/(\d+)').firstMatch(cfi);
      if (match != null) {
        final chapterNum = int.parse(match.group(1)!);
        // CFI uses 1-based indices, adjust
        return (chapterNum ~/ 2) - 1;
      }
    } catch (e) {
      AnxLog.warning('NativeEpubPlayer: Failed to parse CFI: $cfi');
    }
    return 0;
  }

  String _generateCfi() {
    // Generate simplified CFI for current position
    final chapterNum = (_currentChapterIndex + 1) * 2;
    return 'epubcfi(/6/$chapterNum)';
  }

  Future<void> _saveProgress() async {
    if (_parser == null) return;

    final cfi = _generateCfi();
    final percentage = _parser!.chapters.isEmpty
        ? 0.0
        : (_currentChapterIndex + 1) / _parser!.chapters.length;

    Book book = widget.book;
    book.lastReadPosition = cfi;
    book.readingPercentage = percentage;
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
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Loading book...',
                  style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Failed to load book',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Go Back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      drawer: _buildTocDrawer(),
      body: GestureDetector(
        onTap: () => widget.showOrHideAppBarAndBottomBar(),
        child: _buildReaderView(),
      ),
    );
  }

  Widget _buildTocDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Table of Contents',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: _parser?.toc.length ?? 0,
                itemBuilder: (context, index) {
                  final item = _parser!.toc[index];
                  return _buildTocItem(item, 0);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTocItem(TocItem item, int depth) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(left: 16 + depth * 16.0),
          title: Text(item.title),
          onTap: () {
            Navigator.pop(context); // Close drawer
            // Find chapter by href
            final chapterIndex = _parser!.chapters.indexWhere((c) =>
                item.href.contains(c.href) ||
                c.href.contains(item.href.split('#').first));
            if (chapterIndex >= 0) {
              _goToChapter(chapterIndex);
            }
          },
        ),
        ...item.children.map((child) => _buildTocItem(child, depth + 1)),
      ],
    );
  }

  Widget _buildReaderView() {
    if (_parser == null || _parser!.chapters.isEmpty) {
      return const Center(child: Text('No content available'));
    }

    final prefs = Prefs();
    final theme = prefs.readTheme;
    final style = prefs.bookStyle;

    return Container(
      color: Color(int.parse('0xFF${theme.backgroundColor}')),
      child: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) {
          setState(() {
            _currentChapterIndex = index;
          });
        },
        itemCount: _parser!.chapters.length,
        itemBuilder: (context, index) {
          final chapter = _parser!.chapters[index];
          return _buildChapterView(chapter, theme, style);
        },
      ),
    );
  }

  Widget _buildChapterView(EpubChapter chapter, dynamic theme, dynamic style) {
    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(
        horizontal: style.sideMargin.toDouble(),
        vertical: style.topMargin.toDouble(),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Chapter title
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                chapter.title,
                style: TextStyle(
                  fontSize: style.fontSize.toDouble() + 4,
                  fontWeight: FontWeight.bold,
                  color: Color(int.parse('0xFF${theme.textColor}')),
                ),
              ),
            ),
            // Chapter content using flutter_html
            Html(
              data: chapter.htmlContent,
              style: {
                "body": Style(
                  fontSize: FontSize(style.fontSize.toDouble()),
                  color: Color(int.parse('0xFF${theme.textColor}')),
                  lineHeight: LineHeight(style.lineHeight.toDouble()),
                  textAlign: TextAlign.justify,
                ),
                "p": Style(
                  margin: Margins(
                    bottom: Margin(style.paragraphSpacing.toDouble()),
                  ),
                ),
                "img": Style(
                  width: Width(
                      MediaQuery.of(context).size.width - style.sideMargin * 2),
                ),
              },
              onLinkTap: (url, _, __) {
                AnxLog.info('NativeEpubPlayer: Link tapped: $url');
                // Handle internal links (chapter navigation)
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
            // Navigation buttons
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_currentChapterIndex > 0)
                    TextButton.icon(
                      onPressed: _prevChapter,
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Previous'),
                    )
                  else
                    const SizedBox(),
                  Text(
                    '${_currentChapterIndex + 1} / ${_parser!.chapters.length}',
                    style: TextStyle(
                      color: Color(int.parse('0xFF${theme.textColor}'))
                          .withOpacity(0.6),
                    ),
                  ),
                  if (_currentChapterIndex < _parser!.chapters.length - 1)
                    TextButton.icon(
                      onPressed: _nextChapter,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Next'),
                    )
                  else
                    const SizedBox(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
