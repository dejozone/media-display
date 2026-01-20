import 'package:flutter/material.dart';

class AppModalAction {
  const AppModalAction({required this.label, required this.onPressed, this.isPrimary = true});

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
        actions: buttons.map((action) {
          final btn = action.isPrimary
              ? ElevatedButton(
                  onPressed: action.onPressed,
                  child: Text(action.label),
                )
              : TextButton(
                  onPressed: action.onPressed,
                  child: Text(action.label),
                );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: btn,
          );
        }).toList(),
      );
    },
  );
}
