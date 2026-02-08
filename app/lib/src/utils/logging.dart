import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

// Shared logging configuration for the app. Uses env-provided LOG_LEVEL and
// formats entries uniformly for easier correlation with backend logs.
bool _listenerAttached = false;

Level _parseLevel(String? value) {
  switch (value?.toUpperCase().trim()) {
    case 'ALL':
      return Level.ALL;
    case 'FINE':
    case 'DEBUG':
    case 'TRACE':
      return Level.FINE;
    case 'INFO':
    case null:
      return Level.INFO;
    case 'WARNING':
    case 'WARN':
      return Level.WARNING;
    case 'SEVERE':
    case 'ERROR':
      return Level.SEVERE;
    case 'SHOUT':
    case 'FATAL':
      return Level.SHOUT;
    case 'OFF':
      return Level.OFF;
    default:
      return Level.INFO;
  }
}

String _formatTimestamp(DateTime time) {
  final y = time.year.toString();
  final mo = time.month.toString().padLeft(2, '0');
  final d = time.day.toString().padLeft(2, '0');
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  final s = time.second.toString().padLeft(2, '0');
  final ms = time.millisecond.toString().padLeft(3, '0');
  return '$y-$mo-$d $h:$m:$s.$ms';
}

void configureLogging({String? level}) {
  Logger.root.level = _parseLevel(level);

  if (_listenerAttached) return;
  _listenerAttached = true;

  Logger.root.onRecord.listen((record) {
    final ts = _formatTimestamp(record.time);
    final errorSuffix = record.error == null ? '' : ' error=${record.error}';
    final message = record.message;
    final stack = record.stackTrace == null ? '' : '\n${record.stackTrace}';
    debugPrint('[$ts] [${record.level.name}] [${record.loggerName}] '
        '$message$errorSuffix$stack');
  });
}

Logger appLogger(String name) => Logger(name);
