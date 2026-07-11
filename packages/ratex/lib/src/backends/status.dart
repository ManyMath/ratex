import 'dart:convert';

import '../exceptions.dart';

/// Maps an engine status code plus its JSON error payload
/// (`{"message", "start", "end"}`) to the matching exception. Shared by the
/// FFI and wasm backends.
Never throwForStatus(int status, String payload) {
  String message;
  int? start;
  int? end;
  try {
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    message = decoded['message'] as String? ?? payload;
    start = (decoded['start'] as num?)?.toInt();
    end = (decoded['end'] as num?)?.toInt();
  } on Object {
    message = payload;
    start = null;
    end = null;
  }
  switch (status) {
    case 1:
      throw RatexParseException(message, start: start, end: end);
    case 2:
      throw RatexInvalidInputException(message);
    default:
      throw RatexInternalException(message);
  }
}
