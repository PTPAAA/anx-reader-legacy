import 'dart:async';
import 'dart:math' as math;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/dao/theme.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'dart:io';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/read_theme.dart';
import 'package:anx_reader/page/book_detail.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/page/book_player/native_epub_player.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/ui/status_bar.dart';
import 'package:anx_reader/widgets/reading_page/notes_widget.dart';
import 'package:anx_reader/models/reading_time.dart';
import 'package:anx_reader/widgets/reading_page/progress_widget.dart';
import 'package:anx_reader/widgets/reading_page/tts_widget.dart';
import 'package:anx_reader/widgets/reading_page/style_widget.dart';
import 'package:anx_reader/widgets/reading_page/toc_widget.dart';
import 'package:anx_reader/widgets/reading_page/native_toc_widget.dart';
import 'package:anx_reader/widgets/reading_page/native_bookmark_widget.dart';
import 'package:anx_reader/widgets/reading_page/native_style_widget.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// import 'package:flutter/foundation.dart'
// show debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class ReadingPage extends ConsumerStatefulWidget {
  const ReadingPage({
    super.key,
    required this.book,
    this.cfi,
    required this.initialThemes,
    this.heroTag,
  });

  final Book book;
  final String? cfi;
  final List<ReadTheme> initialThemes;
  final String? heroTag;

  @override
  ConsumerState<ReadingPage> createState() => ReadingPageState();
}

final GlobalKey<ReadingPageState> readingPageKey =
    GlobalKey<ReadingPageState>();
final epubPlayerKey = GlobalKey<EpubPlayerState>();
final nativePlayerKey = GlobalKey<NativeEpubPlayerState>();

class ReadingPageState extends ConsumerState<ReadingPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const empty = SizedBox.shrink();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _canPop = false;
  late Book _book;
  late Widget _currentPage = empty;
  final Stopwatch _readTimeWatch = Stopwatch();
  DateTime? _sessionStart;
  Timer? _awakeTimer;
  final ValueNotifier<bool> _controlsVisible = ValueNotifier<bool>(false);
  final ValueNotifier<List<NativeBookmark>> _bookmarksNotifier =
      ValueNotifier([]);
  late String heroTag;

  bool bookmarkExists = false;

  late final FocusNode _readerFocusNode;
  // late final VolumeKeyBoard _volumeKeyBoard;
  // bool _volumeKeyListenerAttached = false;

  @override
  void initState() {
    _readerFocusNode = FocusNode(debugLabel: 'reading_page_focus');
    if (widget.book.isDeleted) {
      Navigator.pop(context);
      AnxToast.show(L10n.of(context).bookDeleted);
      return;
    }
    if (Prefs().hideStatusBar) {
      hideStatusBar();
    }

    WidgetsBinding.instance.addObserver(this);
    _readTimeWatch.start();
    _sessionStart = DateTime.now();
    setAwakeTimer(Prefs().awakeTime);

    _book = widget.book;
    heroTag = widget.heroTag ?? 'preventHeroWhenStart';
    // _volumeKeyBoard = VolumeKeyBoard.instance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _requestReaderFocus();
        // _attachVolumeKeyListener();
      }
    });
    // delay 1000ms to prevent hero animation
    if (widget.heroTag == null) {
      Future.delayed(const Duration(milliseconds: 2000), () {
        if (mounted) {
          setState(() {
            heroTag = _book.coverFullPath;
          });
        }
      });
    }
    if (Platform.isIOS) {
      _loadNativeBookmarks();
    }
    super.initState();
  }

  @override
  void dispose() {
    Sync().syncData(SyncDirection.upload, ref, trigger: SyncTrigger.auto);
    _readTimeWatch.stop();
    _awakeTimer?.cancel();
    WakelockPlus.disable();
    showStatusBar();
    WidgetsBinding.instance.removeObserver(this);
    readingTimeDao.insertReadingTime(
      ReadingTime(
        bookId: _book.id,
        readingTime: _readTimeWatch.elapsed.inSeconds,
      ),
      startedAt: _sessionStart,
    );
    _sessionStart = null;
    audioHandler.stop();
    // if (_volumeKeyListenerAttached) {
    //   unawaited(_volumeKeyBoard.removeListener());
    // }
    _readerFocusNode.dispose();
    _bookmarksNotifier.dispose();
    super.dispose();
  }

  void _requestReaderFocus() {
    if (!_controlsVisible.value && !_readerFocusNode.hasFocus) {
      _readerFocusNode.requestFocus();
    }
  }

  void _releaseReaderFocus() {
    if (_readerFocusNode.hasFocus) {
      _readerFocusNode.unfocus();
    }
  }

  // Future<void> _attachVolumeKeyListener() async {
  //   if (defaultTargetPlatform != TargetPlatform.iOS ||
  //       _volumeKeyListenerAttached) {
  //     return;
  //   }

  //   try {
  //     await _volumeKeyBoard.addListener(_handleVolumeKeyEvent);
  //     _volumeKeyListenerAttached = true;
  //   } catch (error) {
  //     debugPrint('Failed to attach volume key listener: $error');
  //   }
  // }

  // void _handleVolumeKeyEvent(VolumeKey key) {
  //   if (!Prefs().volumeKeyTurnPage || !_readerFocusNode.hasFocus) {
  //     return;
  //   }

  //   if (key == VolumeKey.up) {
  //     epubPlayerKey.currentState?.prevPage();
  //   } else if (key == VolumeKey.down) {
  //     epubPlayerKey.currentState?.nextPage();
  //   }
  // }

  KeyEventResult _handleReaderKeyEvent(FocusNode node, KeyEvent event) {
    if (!_readerFocusNode.hasFocus) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final logicalKey = event.logicalKey;

    if (logicalKey == LogicalKeyboardKey.arrowRight ||
        logicalKey == LogicalKeyboardKey.arrowDown ||
        logicalKey == LogicalKeyboardKey.pageDown ||
        logicalKey == LogicalKeyboardKey.space) {
      epubPlayerKey.currentState?.nextPage();
      return KeyEventResult.handled;
    }

    if (logicalKey == LogicalKeyboardKey.arrowLeft ||
        logicalKey == LogicalKeyboardKey.arrowUp ||
        logicalKey == LogicalKeyboardKey.pageUp) {
      epubPlayerKey.currentState?.prevPage();
      return KeyEventResult.handled;
    }

    if (logicalKey == LogicalKeyboardKey.enter) {
      showOrHideAppBarAndBottomBar(true);
      return KeyEventResult.handled;
    }

    if (Prefs().volumeKeyTurnPage) {
      if (event.physicalKey == PhysicalKeyboardKey.audioVolumeUp) {
        epubPlayerKey.currentState?.prevPage();
        return KeyEventResult.handled;
      }
      if (event.physicalKey == PhysicalKeyboardKey.audioVolumeDown) {
        epubPlayerKey.currentState?.nextPage();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_readTimeWatch.isRunning) {
          _readTimeWatch.start();
        }
        _sessionStart ??= DateTime.now();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_readTimeWatch.isRunning) {
          _readTimeWatch.stop();
        }
        if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) {
          final elapsedSeconds = _readTimeWatch.elapsed.inSeconds;
          if (elapsedSeconds > 5) {
            epubPlayerKey.currentState?.saveReadingProgress();
            readingTimeDao.insertReadingTime(
              ReadingTime(
                bookId: _book.id,
                readingTime: elapsedSeconds,
              ),
              startedAt: _sessionStart,
            );
          }
          _readTimeWatch.reset();
          _sessionStart = null;
        }
        break;
    }
  }

  Future<void> setAwakeTimer(int minutes) async {
    _awakeTimer?.cancel();
    _awakeTimer = null;
    WakelockPlus.enable();
    _awakeTimer = Timer.periodic(Duration(minutes: minutes), (timer) {
      WakelockPlus.disable();
      _awakeTimer?.cancel();
      _awakeTimer = null;
    });
  }

  void resetAwakeTimer() {
    setAwakeTimer(Prefs().awakeTime);
  }

  void showBottomBar() {
    showStatusBarWithoutResize();
    _controlsVisible.value = true;
    _releaseReaderFocus();
  }

  void hideBottomBar() {
    setState(() {
      _currentPage = empty;
    });
    _controlsVisible.value = false;
    if (Prefs().hideStatusBar) {
      hideStatusBar();
    }
    _requestReaderFocus();
  }

  void showOrHideAppBarAndBottomBar(bool show) {
    if (show) {
      showBottomBar();
    } else {
      hideBottomBar();
    }
  }

  Future<void> tocHandler() async {
    hideBottomBar();
    _scaffoldKey.currentState?.openDrawer();
  }

  void noteHandler() {
    setState(() {
      _currentPage = ReadingNotes(book: _book);
    });
  }

  void progressHandler() {
    setState(() {
      _currentPage = ProgressWidget(
        epubPlayerKey: epubPlayerKey,
        showOrHideAppBarAndBottomBar: showOrHideAppBarAndBottomBar,
      );
    });
  }

  Future<void> styleHandler(StateSetter modalSetState) async {
    List<ReadTheme> themes = await themeDao.selectThemes();
    setState(() {
      _currentPage = StyleWidget(
        themes: themes,
        epubPlayerKey: epubPlayerKey,
        setCurrentPage: (Widget page) {
          modalSetState(() {
            _currentPage = page;
          });
        },
        hideAppBarAndBottomBar: showOrHideAppBarAndBottomBar,
      );
    });
  }

  Future<void> ttsHandler() async {
    setState(() {
      _currentPage = TtsWidget(
        epubPlayerKey: epubPlayerKey,
      );
    });
  }

  Future<void> onLoadEnd() async {}

  void updateState() {
    if (mounted) {
      setState(() {
        bookmarkExists = epubPlayerKey.currentState!.bookmarkExists;
      });
    }
  }

  Future<void> _loadNativeBookmarks() async {
    final notes = await bookNoteDao.selectBookNotesByBookId(_book.id);
    final nativeBookmarks = <NativeBookmark>[];

    AnxLog.info('Loading native bookmarks: found ${notes.length} notes');

    for (var note in notes) {
      if (note.type == 'bookmark' && note.cfi.startsWith('native_pos_v1:')) {
        try {
          final parts = note.cfi.split(':');
          if (parts.length == 3) {
            final chapterIndex = int.parse(parts[1]);
            final scrollPosition = double.parse(parts[2]);
            nativeBookmarks.add(NativeBookmark(
              id: note.id.toString(),
              chapterIndex: chapterIndex,
              scrollPosition: scrollPosition,
              label: note.content,
              createdAt: note.createTime ?? DateTime.now(),
            ));
          }
        } catch (e) {
          AnxLog.warning('Failed to parse native bookmark cfi: ${note.cfi}');
        }
      }
    }
    AnxLog.info('Parsed ${nativeBookmarks.length} valid native bookmarks');
    _bookmarksNotifier.value = nativeBookmarks;
  }

  void _onAddBookmark() async {
    AnxLog.info('User clicked add bookmark');
    final currentState = nativePlayerKey.currentState;
    if (currentState == null) {
      AnxLog.warning('NativeEpubPlayer state is null');
      return;
    }

    final bookmarkData = currentState.createBookmarkData();
    final note = BookNote(
      bookId: _book.id,
      content: bookmarkData.label,
      cfi:
          'native_pos_v1:${bookmarkData.chapterIndex}:${bookmarkData.scrollPosition}',
      chapter: currentState.chapterTitle,
      type: 'bookmark',
      color: '',
      updateTime: DateTime.now(),
      createTime: DateTime.now(),
    );

    await bookNoteDao.save(note);
    AnxToast.show('Bookmark added'); // Use toast
    _loadNativeBookmarks();
  }

  void _onDeleteBookmark(String id) async {
    final intId = int.tryParse(id);
    if (intId != null) {
      await bookNoteDao.deleteBookNoteById(intId);
      _loadNativeBookmarks();
    }
  }

  void _onGoToBookmark(NativeBookmark bookmark) {
    nativePlayerKey.currentState?.goToBookmark(bookmark);
  }

  @override
  Widget build(BuildContext context) {
    Widget controller = ValueListenableBuilder<bool>(
        valueListenable: _controlsVisible,
        builder: (context, visible, child) {
          return Offstage(
            offstage: !visible,
            child: PointerInterceptor(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                        onTap: () {
                          showOrHideAppBarAndBottomBar(false);
                        },
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragUpdate: (details) {},
                        onVerticalDragEnd: (details) {},
                        child: Container(
                          color: Colors.black.withAlpha(30),
                        )),
                  ),
                  Column(
                    children: [
                      AppBar(
                        title:
                            Text(_book.title, overflow: TextOverflow.ellipsis),
                        leading: IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () {
                            // close reading page
                            Navigator.pop(context);
                          },
                        ),
                        actions: [
                          // Hide bookmark button on iOS (use dock button instead)
                          if (!Platform.isIOS)
                            IconButton(
                                onPressed: () {
                                  if (bookmarkExists) {
                                    epubPlayerKey.currentState!
                                        .removeAnnotation(
                                      epubPlayerKey.currentState!.bookmarkCfi,
                                    );
                                  } else {
                                    epubPlayerKey.currentState!
                                        .addBookmarkHere();
                                  }
                                },
                                icon: bookmarkExists
                                    ? const Icon(Icons.bookmark)
                                    : const Icon(Icons.bookmark_border)),
                          IconButton(
                            icon: const Icon(EvaIcons.more_vertical),
                            onPressed: () {
                              Navigator.push(
                                context,
                                CupertinoPageRoute(
                                  builder: (context) =>
                                      BookDetail(book: widget.book),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      const Spacer(),
                      BottomSheet(
                        onClosing: () {},
                        enableDrag: false,
                        builder: (context) => SafeArea(
                          top: false,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 600),
                            child: StatefulBuilder(
                              builder:
                                  (BuildContext context, StateSetter setState) {
                                final hasContent =
                                    !identical(_currentPage, empty);
                                return IntrinsicHeight(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (hasContent)
                                        Expanded(
                                          child: _currentPage,
                                        ),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceAround,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.toc),
                                            onPressed: tocHandler,
                                          ),
                                          // Bookmark button for iOS
                                          if (Platform.isIOS)
                                            IconButton(
                                              icon: const Icon(
                                                  Icons.bookmark_outline),
                                              onPressed: () {
                                                setState(() {
                                                  _currentPage =
                                                      NativeBookmarkWidget(
                                                    bookmarksNotifier:
                                                        _bookmarksNotifier,
                                                    onAddBookmark:
                                                        _onAddBookmark,
                                                    onDeleteBookmark:
                                                        _onDeleteBookmark,
                                                    onGoToBookmark:
                                                        _onGoToBookmark,
                                                    getChapterTitle: (index) {
                                                      final chapters =
                                                          nativePlayerKey
                                                              .currentState
                                                              ?.parser
                                                              ?.chapters;
                                                      if (chapters != null &&
                                                          index >= 0 &&
                                                          index <
                                                              chapters.length) {
                                                        return chapters[index]
                                                            .title;
                                                      }
                                                      return 'Page ${index + 1}';
                                                    },
                                                    hideAppBarAndBottomBar:
                                                        showOrHideAppBarAndBottomBar,
                                                    closeDrawer: () {},
                                                  );
                                                });
                                              },
                                            ),
                                          // Hide notes on iOS (not supported in native reader)
                                          if (!Platform.isIOS)
                                            IconButton(
                                              icon: const Icon(EvaIcons.edit),
                                              onPressed: noteHandler,
                                            ),
                                          // Hide progress on iOS (shown in native status bar)
                                          if (!Platform.isIOS)
                                            IconButton(
                                              icon:
                                                  const Icon(Icons.data_usage),
                                              onPressed: progressHandler,
                                            ),
                                          IconButton(
                                            icon: const Icon(Icons.color_lens),
                                            onPressed: () {
                                              if (Platform.isIOS) {
                                                setState(() {
                                                  _currentPage =
                                                      NativeStyleWidget(
                                                    onStyleChanged: () =>
                                                        setState(() {}),
                                                  );
                                                });
                                              } else {
                                                styleHandler(setState);
                                              }
                                            },
                                          ),
                                          // Hide TTS on iOS (not supported in native reader)
                                          if (!Platform.isIOS)
                                            IconButton(
                                              icon: const Icon(
                                                  EvaIcons.headphones),
                                              onPressed: ttsHandler,
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        });

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (Platform.isIOS &&
            nativePlayerKey.currentState != null &&
            nativePlayerKey.currentState!.mounted) {
          await nativePlayerKey.currentState?.saveProgress();
        }

        if (mounted) {
          setState(() {
            _canPop = true;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop();
          });
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        resizeToAvoidBottomInset: false,
        drawer: PointerInterceptor(
          child: Drawer(
            width: math.min(
              MediaQuery.of(context).size.width * 0.8,
              420,
            ),
            child: SafeArea(
              child: Platform.isIOS
                  ? NativeTocWidget(
                      nativePlayerKey: nativePlayerKey,
                      hideAppBarAndBottomBar: showOrHideAppBarAndBottomBar,
                      closeDrawer: () {
                        _scaffoldKey.currentState?.closeDrawer();
                      },
                    )
                  : TocWidget(
                      epubPlayerKey: epubPlayerKey,
                      hideAppBarAndBottomBar: showOrHideAppBarAndBottomBar,
                      closeDrawer: () {
                        _scaffoldKey.currentState?.closeDrawer();
                      },
                    ),
            ),
          ),
        ),
        body: Stack(
          children: [
            Row(
              children: [
                Expanded(
                  child: MouseRegion(
                    onHover: (PointerHoverEvent detail) {
                      var y = detail.position.dy;
                      if (y < 30 ||
                          y > MediaQuery.of(context).size.height - 30) {
                        showOrHideAppBarAndBottomBar(true);
                      }
                    },
                    child: Focus(
                      focusNode: _readerFocusNode,
                      onKeyEvent: _handleReaderKeyEvent,
                      child: Stack(
                        children: [
                          // Use NativeEpubPlayer on iOS for compatibility
                          // WebView-based EpubPlayer may have issues on iOS 14
                          if (Platform.isIOS)
                            NativeEpubPlayer(
                              key: nativePlayerKey,
                              book: _book,
                              cfi: widget.cfi,
                              showOrHideAppBarAndBottomBar: (show) =>
                                  showOrHideAppBarAndBottomBar(show),
                              onLoadEnd: onLoadEnd,
                              bookmarksNotifier: _bookmarksNotifier,
                            )
                          else
                            EpubPlayer(
                              key: epubPlayerKey,
                              book: _book,
                              cfi: widget.cfi,
                              showOrHideAppBarAndBottomBar:
                                  showOrHideAppBarAndBottomBar,
                              onLoadEnd: onLoadEnd,
                              initialThemes: widget.initialThemes,
                              updateParent: updateState,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            controller,
          ],
        ),
      ),
    );
  }
}
