import 'models.dart';

class HttpRangeCalculator {
  /// Maximum practical content length (2^53, ~9 PB).
  /// Dart int is 64-bit but HTTP Content-Length headers above this value
  /// are unrealistic and risk overflow in chunk arithmetic.
  static const int _maxContentLength = 9007199254740992; // 2^53

  static List<DownloadChunk> calculate({
    required int contentLength,
    required int maxChunks,
  }) {
    if (contentLength <= 0) {
      return [];
    }
    if (maxChunks <= 0) {
      throw ArgumentError('maxChunks must be greater than 0');
    }
    // Clamp to a realistic maximum to prevent integer overflow in
    // chunk boundary arithmetic (chunkSize + extra, start + length - 1).
    if (contentLength > _maxContentLength) {
      contentLength = _maxContentLength;
    }

    final actualChunks = maxChunks > contentLength ? contentLength : maxChunks;
    final int chunkSize = contentLength ~/ actualChunks;
    final int remainder = contentLength % actualChunks;

    final List<DownloadChunk> chunks = [];
    int start = 0;

    for (int i = 0; i < actualChunks; i++) {
      final int extra = i < remainder ? 1 : 0;
      final int length = chunkSize + extra;
      final int end = start + length - 1;

      chunks.add(
        DownloadChunk(
          index: i,
          start: start,
          end: end,
          bytesDownloaded: 0,
          isCompleted: false,
        ),
      );
      start = end + 1;
    }

    return chunks;
  }
}
