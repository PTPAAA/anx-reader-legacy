import 'dart:convert';

import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';

class ParsedReasoning {
  const ParsedReasoning({
    required this.timeline,
  });

  final List<ParsedReasoningEntry> timeline;

  bool get hasReplies =>
      timeline.any((entry) => entry.type == ParsedReasoningEntryType.reply);

  bool get hasToolSteps =>
      timeline.any((entry) => entry.type == ParsedReasoningEntryType.tool);

  List<ParsedToolStep> get toolSteps => timeline
      .where((entry) => entry.type == ParsedReasoningEntryType.tool)
      .map((entry) => entry.toolStep!)
      .toList(growable: false);
}

enum ParsedReasoningEntryType { reply, tool }

class ParsedReasoningEntry {
  const ParsedReasoningEntry.reply(this.text)
      : toolStep = null,
        type = ParsedReasoningEntryType.reply;

  const ParsedReasoningEntry.tool(this.toolStep)
      : text = null,
        type = ParsedReasoningEntryType.tool;

  final String? text;
  final ParsedToolStep? toolStep;
  final ParsedReasoningEntryType type;
}

class ParsedToolStep {
  const ParsedToolStep({
    required this.name,
    required this.status,
    this.input,
    this.output,
    this.error,
  });

  final String name;
  final String status;
  final String? input;
  final String? output;
  final String? error;
}

ParsedReasoning parseReasoningContent(String content) {
  final timeline = <ParsedReasoningEntry>[];
  final thinkRegex = RegExp(r'<think>([\s\S]*?)<\/think>');
  var remaining = content;

  final matches = thinkRegex.allMatches(content).toList(growable: false);
  if (matches.isNotEmpty) {
    for (final match in matches) {
      final inner = match.group(1);
      if (inner != null && inner.isNotEmpty) {
        _parseTimeline(inner, timeline);
      }
    }
    remaining = content.replaceAll(thinkRegex, '');
  }

  if (remaining.isNotEmpty) {
    _parseTimeline(remaining, timeline);
  }

  return ParsedReasoning(timeline: timeline);
}

Map<String, String> _parseAttributes(String raw) {
  final attrs = <String, String>{};
  final attrRegex = RegExp(r"(\w+)='([^']*)'");
  for (final match in attrRegex.allMatches(raw)) {
    attrs[match.group(1)!] = match.group(2)!;
  }
  return attrs;
}

String? _decodeAttrValue(Map<String, String> attrs, String key) {
  final direct = attrs[key];
  if (direct != null) {
    return _unescapeAttr(direct);
  }
  final encoded = attrs['${key}_b64'];
  if (encoded != null) {
    final decoded = utf8.decode(base64Decode(_unescapeAttr(encoded)));
    return decoded;
  }
  return null;
}

String _unescapeAttr(String value) {
  return Uri.decodeComponent(value);
}

void _parseTimeline(String source, List<ParsedReasoningEntry> timeline) {
  if (source.isEmpty) {
    return;
  }

  final tagRegex = RegExp(r'<(tool-step|reply|think-block)\s+([^/>]+?)\s*/>');
  var currentIndex = 0;
  var buffer = StringBuffer();

  void flushBuffer() {
    final chunk = buffer.toString();
    buffer = StringBuffer();
    if (chunk.isEmpty) {
      return;
    }
    timeline.add(ParsedReasoningEntry.reply(chunk));
  }

  for (final match in tagRegex.allMatches(source)) {
    final preceding = source.substring(currentIndex, match.start);
    if (preceding.isNotEmpty) {
      buffer.write(preceding);
    }

    final tagName = match.group(1)!;
    final attrs = _parseAttributes(match.group(2)!);

    if (tagName == 'tool-step') {
      flushBuffer();
      timeline.add(
        ParsedReasoningEntry.tool(
          ParsedToolStep(
            name: _unescapeAttr(attrs['name'] ?? ''),
            status: (attrs['status'] ?? 'pending').toLowerCase(),
            input: _decodeAttrValue(attrs, 'input'),
            output: _decodeAttrValue(attrs, 'output'),
            error: _decodeAttrValue(attrs, 'error'),
          ),
        ),
      );
    } else {
      final decoded = _decodeAttrValue(attrs, 'text');
      final text = decoded ?? _unescapeAttr(attrs['text'] ?? '');
      if (text.isNotEmpty) {
        flushBuffer();
        timeline.add(ParsedReasoningEntry.reply(text));
      }
    }

    currentIndex = match.end;
  }

  final trailing = source.substring(currentIndex);
  if (trailing.isNotEmpty) {
    buffer.write(trailing);
  }
  flushBuffer();
}

String reasoningContentToPlainText(String content) {
  final parsed = parseReasoningContent(content);
  if (parsed.timeline.isEmpty) {
    return content;
  }

  final sections = <String>[];

  for (final entry in parsed.timeline) {
    switch (entry.type) {
      case ParsedReasoningEntryType.reply:
        final text = entry.text;
        if (text != null && text.isNotEmpty) {
          sections.add(text);
        }
        break;
      case ParsedReasoningEntryType.tool:
        final step = entry.toolStep;
        if (step != null) {
          final toolName = AiToolRegistry.displayNameForId(step.name);
          final lines = <String>['[Tool $toolName ${step.status}]'];
          final output = step.output?.trim();
          if (output != null && output.isNotEmpty) {
            lines.add(output);
          }
          final error = step.error?.trim();
          if (error != null && error.isNotEmpty) {
            lines.add('Error: $error');
          }
          final input = step.input?.trim();
          if (input != null && input.isNotEmpty) {
            lines.add('Input: $input');
          }
          final section = lines.join('\n').trim();
          if (section.isNotEmpty) {
            sections.add(section);
          }
        }
        break;
    }
  }

  final result = sections.join('\n\n').trim();
  return result.isEmpty ? content : result;
}
