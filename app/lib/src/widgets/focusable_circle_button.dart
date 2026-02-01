import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A circular, focus-aware clickable surface suitable for TV/keyboard navigation.
/// Highlights on focus/hover and preserves a consistent 48x48 hit target.
class FocusableCircleButton extends StatefulWidget {
  const FocusableCircleButton({
    super.key,
    required this.child,
    this.onPressed,
    this.tooltip,
    this.size = 48,
    this.backgroundColor = const Color(0xFF1A2333),
    this.focusBorderColor = const Color(0xFF5AC8FA),
    this.defaultBorderColor = const Color(0x14FFFFFF), // 8% alpha white
  });

  final Widget child;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final Color backgroundColor;
  final Color focusBorderColor;
  final Color defaultBorderColor;

  @override
  State<FocusableCircleButton> createState() => _FocusableCircleButtonState();
}

class _FocusableCircleButtonState extends State<FocusableCircleButton> {
  bool _focused = false;
  bool _hovered = false;

  static final Set<LogicalKeyboardKey> _activationKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || widget.onPressed == null) {
      return KeyEventResult.ignored;
    }
    if (_activationKeys.contains(event.logicalKey)) {
      widget.onPressed!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _updateFocus(bool focused) {
    if (_focused != focused) {
      setState(() => _focused = focused);
    }
  }

  void _updateHover(bool hovered) {
    if (_hovered != hovered) {
      setState(() => _hovered = hovered);
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _focused
        ? widget.focusBorderColor
        : (_hovered
            ? widget.defaultBorderColor.withOpacity(0.4)
            : widget.defaultBorderColor);

    final activationShortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
      const SingleActivator(LogicalKeyboardKey.numpadEnter):
          const ActivateIntent(),
      const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
      const SingleActivator(LogicalKeyboardKey.space): const ActivateIntent(),
      const SingleActivator(LogicalKeyboardKey.gameButtonA):
          const ActivateIntent(),
    };

    return Semantics(
      button: true,
      enabled: widget.onPressed != null,
      label: widget.tooltip,
      child: FocusableActionDetector(
        shortcuts: activationShortcuts,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (widget.onPressed != null) {
                widget.onPressed!();
              }
              return null;
            },
          ),
        },
        onShowFocusHighlight: _updateFocus,
        onShowHoverHighlight: _updateHover,
        child: Focus(
          canRequestFocus: widget.onPressed != null,
          skipTraversal: false,
          onKeyEvent: _handleKeyEvent,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: widget.backgroundColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: borderColor),
                  boxShadow: _focused
                      ? [
                          BoxShadow(
                            color: widget.focusBorderColor.withOpacity(0.25),
                            blurRadius: 12,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: widget.tooltip != null
                      ? Tooltip(
                          message: widget.tooltip!,
                          child: widget.child,
                        )
                      : widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
