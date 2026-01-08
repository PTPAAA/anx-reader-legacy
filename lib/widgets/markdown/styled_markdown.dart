import 'package:anx_reader/widgets/markdown/selection_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// A custom Markdown widget with theme-aware styling.
/// This widget provides better contrast and readability in both light and dark modes.
class StyledMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;

  const StyledMarkdown({
    super.key,
    required this.data,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Simple markdown to HTML conversion for basic formatting
    final htmlContent = _markdownToHtml(data);

    return SelectableRegion(
      focusNode: FocusNode(),
      selectionControls: selectionControls(),
      child: Html(
        data: htmlContent,
        style: {
          'body': Style(
            fontSize: FontSize(14),
            color: theme.textTheme.bodyMedium?.color,
          ),
          'a': Style(
            color: theme.colorScheme.primary,
            textDecoration: TextDecoration.underline,
          ),
          'code': Style(
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            padding: HtmlPaddings.symmetric(horizontal: 4, vertical: 2),
          ),
          'pre': Style(
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            padding: HtmlPaddings.all(8),
          ),
          'blockquote': Style(
            border: Border(
              left: BorderSide(
                color: theme.colorScheme.primary,
                width: 4,
              ),
            ),
            padding: HtmlPaddings.only(left: 12),
            margin: Margins.symmetric(vertical: 8),
          ),
        },
        onLinkTap: (url, _, __) {
          if (url != null) {
            launchUrlString(url);
          }
        },
      ),
    );
  }

  /// Basic markdown to HTML conversion
  String _markdownToHtml(String markdown) {
    var html = markdown;

    // Headers
    html = html.replaceAllMapped(
        RegExp(r'^### (.+)$', multiLine: true), (m) => '<h3>${m[1]}</h3>');
    html = html.replaceAllMapped(
        RegExp(r'^## (.+)$', multiLine: true), (m) => '<h2>${m[1]}</h2>');
    html = html.replaceAllMapped(
        RegExp(r'^# (.+)$', multiLine: true), (m) => '<h1>${m[1]}</h1>');

    // Bold and italic
    html = html.replaceAllMapped(
        RegExp(r'\*\*(.+?)\*\*'), (m) => '<strong>${m[1]}</strong>');
    html =
        html.replaceAllMapped(RegExp(r'\*(.+?)\*'), (m) => '<em>${m[1]}</em>');

    // Code blocks
    html = html.replaceAllMapped(RegExp(r'```[\w]*\n([\s\S]*?)```'),
        (m) => '<pre><code>${m[1]}</code></pre>');
    html = html.replaceAllMapped(
        RegExp(r'`([^`]+)`'), (m) => '<code>${m[1]}</code>');

    // Links
    html = html.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
        (m) => '<a href="${m[2]}">${m[1]}</a>');

    // Lists
    html = html.replaceAllMapped(
        RegExp(r'^- (.+)$', multiLine: true), (m) => '<li>${m[1]}</li>');
    html = html.replaceAllMapped(
        RegExp(r'(<li>.*<\/li>\n?)+'), (match) => '<ul>${match.group(0)}</ul>');

    // Paragraphs (simple newlines)
    html = html.replaceAll('\n\n', '</p><p>');
    html = '<p>$html</p>';

    return html;
  }
}
