import 'package:flutter/material.dart';
import 'package:anx_reader/service/native_epub_parser.dart';
import 'package:anx_reader/page/book_player/native_epub_player.dart';

/// Native TOC widget for iOS 14 compatible reader
class NativeTocWidget extends StatelessWidget {
  final GlobalKey<NativeEpubPlayerState> nativePlayerKey;
  final Function(bool) hideAppBarAndBottomBar;
  final VoidCallback closeDrawer;

  const NativeTocWidget({
    super.key,
    required this.nativePlayerKey,
    required this.hideAppBarAndBottomBar,
    required this.closeDrawer,
  });

  @override
  Widget build(BuildContext context) {
    final playerState = nativePlayerKey.currentState;
    if (playerState == null || playerState.parser == null) {
      return Center(
        child: Text('目录加载中...', style: Theme.of(context).textTheme.bodyLarge),
      );
    }

    final toc = playerState.toc;
    final currentIndex = playerState.currentChapterIndex;

    if (toc.isEmpty) {
      // Fallback to chapter list
      return _buildChapterList(context, playerState, currentIndex);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '目录',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: toc.length,
            itemBuilder: (context, index) {
              return _buildTocItem(
                  context, toc[index], 0, playerState, currentIndex);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildChapterList(BuildContext context,
      NativeEpubPlayerState playerState, int currentIndex) {
    final chapters = playerState.parser!.chapters;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '章节',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: chapters.length,
            itemBuilder: (context, index) {
              final chapter = chapters[index];
              final isActive = index == currentIndex;

              return ListTile(
                title: Text(
                  chapter.title,
                  style: TextStyle(
                    color:
                        isActive ? Theme.of(context).colorScheme.primary : null,
                    fontWeight: isActive ? FontWeight.w600 : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: isActive
                    ? Icon(Icons.arrow_forward_ios,
                        size: 14, color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () {
                  playerState.goToChapter(index);
                  closeDrawer();
                  hideAppBarAndBottomBar(false);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTocItem(BuildContext context, TocItem item, int depth,
      NativeEpubPlayerState playerState, int currentIndex) {
    // Check if this TOC item corresponds to current chapter
    final isActive = playerState.parser!.chapters.any((c) {
      final idx = playerState.parser!.chapters.indexOf(c);
      if (idx != currentIndex) return false;
      return item.href.contains(c.href) ||
          c.href.contains(item.href.split('#').first);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(left: 16 + depth * 20.0, right: 16),
          title: Text(
            item.title,
            style: TextStyle(
              color: isActive ? Theme.of(context).colorScheme.primary : null,
              fontWeight: isActive ? FontWeight.w600 : null,
              fontSize: 15,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: isActive
              ? Icon(Icons.arrow_forward_ios,
                  size: 14, color: Theme.of(context).colorScheme.primary)
              : null,
          onTap: () {
            // Find chapter by href
            final chapterIndex = playerState.parser!.chapters.indexWhere((c) =>
                item.href.contains(c.href) ||
                c.href.contains(item.href.split('#').first));
            if (chapterIndex >= 0) {
              playerState.goToChapter(chapterIndex);
              closeDrawer();
              hideAppBarAndBottomBar(false);
            }
          },
        ),
        ...item.children.map((child) => _buildTocItem(
            context, child, depth + 1, playerState, currentIndex)),
      ],
    );
  }
}
