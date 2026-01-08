import 'package:flutter/material.dart';
import 'package:anx_reader/page/book_player/native_epub_player.dart';

/// Native bookmark widget for iOS reader
/// Uses ValueListenableBuilder for reactive updates without full widget rebuilds
class NativeBookmarkWidget extends StatelessWidget {
  final GlobalKey<NativeEpubPlayerState> nativePlayerKey;
  final Function(bool) hideAppBarAndBottomBar;
  final VoidCallback closeDrawer;

  const NativeBookmarkWidget({
    super.key,
    required this.nativePlayerKey,
    required this.hideAppBarAndBottomBar,
    required this.closeDrawer,
  });

  @override
  Widget build(BuildContext context) {
    final playerState = nativePlayerKey.currentState;
    if (playerState == null) {
      return const Center(child: Text('书签加载中...'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '书签',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  playerState.addBookmark();
                  // No setState needed - ValueNotifier handles updates
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Use ValueListenableBuilder for reactive bookmark list updates
        Expanded(
          child: ValueListenableBuilder<List<NativeBookmark>>(
            valueListenable: playerState.bookmarksNotifier,
            builder: (context, bookmarks, child) {
              if (bookmarks.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bookmark_outline,
                          size: 48, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('暂无书签', style: TextStyle(color: Colors.grey)),
                      SizedBox(height: 4),
                      Text('点击上方"添加"保存当前位置',
                          style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                );
              }

              return ListView.builder(
                itemCount: bookmarks.length,
                itemBuilder: (context, index) {
                  final bookmark = bookmarks[bookmarks.length - 1 - index];
                  return ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.bookmark,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    title: Text(
                      bookmark.label,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      playerState
                              .parser?.chapters[bookmark.chapterIndex].title ??
                          '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () {
                        playerState.deleteBookmark(bookmark.id);
                        // No setState needed - ValueNotifier handles updates
                      },
                    ),
                    onTap: () {
                      playerState.goToBookmark(bookmark);
                      closeDrawer();
                      hideAppBarAndBottomBar(false);
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
