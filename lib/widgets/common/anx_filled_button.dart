import 'package:flutter/material.dart';

class AnxFilledButton extends StatelessWidget {
  const AnxFilledButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.disabled = false,
    this.style,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
  })  : icon = null,
        label = null;

  const AnxFilledButton.icon({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.disabled = false,
    this.style,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
  }) : child = null;

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip clipBehavior;
  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? effectiveOnPressed = disabled ? null : onPressed;
    final VoidCallback? effectiveOnLongPress = disabled ? null : onLongPress;

    // Check if this is an icon button
    if (icon != null && label != null) {
      return FilledButton.icon(
        onPressed: effectiveOnPressed,
        onLongPress: effectiveOnLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        clipBehavior: clipBehavior,
        icon: icon!,
        label: label!,
      );
    }

    return FilledButton(
      onPressed: effectiveOnPressed,
      onLongPress: effectiveOnLongPress,
      onHover: onHover,
      onFocusChange: onFocusChange,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      clipBehavior: clipBehavior,
      child: child!,
    );
  }
}
