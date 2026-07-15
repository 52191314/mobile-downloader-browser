import 'models.dart';

class HttpRangeCalculator {
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
