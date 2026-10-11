import 'dart:convert';
import 'dart:typed_data';

import '../exceptions.dart';

/// Maps an engine status code plus its JSON error payload
/// (`{"message", "start", "end"}`) to the matching exception. Shared by the
/// FFI and wasm backends. The engine's spans are byte offsets into the
/// UTF-8 [input]; they are converted to indices into the Dart string.
Never throwForStatus(int status, String payload, Uint8List input) {
  String message;
  int? start;
  int? end;
  try {
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    message = decoded['message'] as String? ?? payload;
    start = _stringIndex(input, (decoded['start'] as num?)?.toInt());
    end = _stringIndex(input, (decoded['end'] as num?)?.toInt());
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

/// The UTF-16 index matching [byteOffset] into the UTF-8 [input], or null
/// when the offset is out of range or splits a character.
int? _stringIndex(Uint8List input, int? byteOffset) {
  if (byteOffset == null || byteOffset < 0 || byteOffset > input.length) {
    return null;
  }
  try {
    return utf8.decode(Uint8List.sublistView(input, 0, byteOffset)).length;
  } on FormatException {
    return null;
  }
}
