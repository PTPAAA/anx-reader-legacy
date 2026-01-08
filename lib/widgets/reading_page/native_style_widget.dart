import 'package:flutter/material.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book_style.dart';
import 'package:anx_reader/page/reading_page.dart';

/// Simplified style widget for iOS native reader
class NativeStyleWidget extends StatefulWidget {
  final VoidCallback onStyleChanged;

  const NativeStyleWidget({
    super.key,
    required this.onStyleChanged,
  });

  @override
  State<NativeStyleWidget> createState() => _NativeStyleWidgetState();
}

class _NativeStyleWidgetState extends State<NativeStyleWidget> {
  late BookStyle _style;

  @override
  void initState() {
    super.initState();
    _style = Prefs().bookStyle;
  }

  void _updateStyle() {
    Prefs().saveBookStyleToPrefs(_style);
    widget.onStyleChanged();
    nativePlayerKey.currentState?.setState(() {});
  }

  void _resetToDefault() {
    setState(() {
      _style = BookStyle(); // Default values
    });
    _updateStyle();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '阅读样式',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              TextButton.icon(
                onPressed: _resetToDefault,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重置'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Font size
          _buildSliderRow(
            icon: Icons.format_size,
            label: '字体大小',
            value: _style.fontSize,
            min: 0.8,
            max: 2.5,
            displayValue: '${(_style.fontSize * 16).round()}',
            onChanged: (v) {
              setState(() => _style = _style.copyWith(fontSize: v));
              _updateStyle();
            },
          ),

          const SizedBox(height: 12),

          // Line height
          _buildSliderRow(
            icon: Icons.format_line_spacing,
            label: '行间距',
            value: _style.lineHeight,
            min: 1.2,
            max: 2.5,
            displayValue: _style.lineHeight.toStringAsFixed(1),
            onChanged: (v) {
              setState(() => _style = _style.copyWith(lineHeight: v));
              _updateStyle();
            },
          ),

          const SizedBox(height: 12),

          // Side margin
          _buildSliderRow(
            icon: Icons.format_indent_increase,
            label: '边距',
            value: _style.sideMargin,
            min: 4.0,
            max: 40.0,
            displayValue: '${_style.sideMargin.round()}',
            onChanged: (v) {
              setState(() => _style = _style.copyWith(sideMargin: v));
              _updateStyle();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSliderRow({
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            displayValue,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}
