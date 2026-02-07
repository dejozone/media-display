import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppModalAction {
  const AppModalAction(
      {required this.label, required this.onPressed, this.isPrimary = true});

  final String label;
  final VoidCallback onPressed;
  final bool isPrimary;
}

Future<void> showAppModal({
  required BuildContext context,
  required String title,
  required String message,
  List<AppModalAction>? actions,
  bool useRootNavigator = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final buttons = actions?.isNotEmpty == true
      ? actions!
      : [
          AppModalAction(
            label: 'OK',
            onPressed: () => navigator.pop(),
            isPrimary: true,
          ),
        ];

  return showDialog<void>(
    context: context,
    useRootNavigator: useRootNavigator,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF111624),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(message),
        actions: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: buttons.map((action) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _FocusableModalButton(
                  action: action,
                ),
              );
            }).toList(),
          ),
        ],
      );
    },
  );
}

class _FocusableModalButton extends StatefulWidget {
  const _FocusableModalButton({
    required this.action,
  });

  final AppModalAction action;

  @override
  State<_FocusableModalButton> createState() => _FocusableModalButtonState();
}

class _FocusableModalButtonState extends State<_FocusableModalButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.action.onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: FocusableActionDetector(
        onShowFocusHighlight: (focused) {
          setState(() => _focused = focused);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused ? const Color(0xFF5AC8FA) : Colors.transparent,
              width: 2,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: const Color(0xFF5AC8FA).withValues(alpha: 0.25),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: widget.action.isPrimary
              ? ElevatedButton(
                  onPressed: widget.action.onPressed,
                  child: Text(widget.action.label),
                )
              : TextButton(
                  onPressed: widget.action.onPressed,
                  child: Text(widget.action.label),
                ),
        ),
      ),
    );
  }
}
