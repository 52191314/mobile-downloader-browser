# Handoff Report — Milestone 2: Core Multi-threaded Downloader Design

## 1. Observation

The current state of the `aurora_downloader` codebase and requirements were analyzed. The following observations were made:

### 1.1 Project Structure and Versioning
*   **Target Path**: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`
*   **Dart SDK Constraint**: In `pubspec.yaml` (lines 21-22):
    ```yaml
    environment:
      sdk: ^3.8.1
    ```
*   **Dependencies**: Currently, `pubspec.yaml` contains only `flutter` and `cupertino_icons` under `dependencies` (lines 30-36):
    ```yaml
    dependencies:
      flutter:
        sdk: flutter

      # The following adds the Cupertino Icons font to your application.
      # Use with the CupertinoIcons class for iOS style icons.
      cupertino_icons: ^1.0.8
    ```
*   **Starter Code**: `lib/main.dart` is the default Flutter Counter App template. No downloader code or dependencies exist yet.

### 1.2 Orchestrator Specifications
*   From `.agents/orchestrator/plan.md` (lines 18-19):
    ```
    | 2 | Core Multi-threaded Downloader (R1) | Multi-threaded HTTP Range request calculations, chunks download, chunk joining, pause/resume, SHA-256, Unit tests | M1 | IN_PROGRESS |
    ```
    This indicates that Milestone 2 requires Range requests, chunk downloading, chunk joining, pause/resume support, SHA-256 validation, and Unit tests.

---

## 2. Logic Chain

Based on these observations, the following architectural and library design decisions were formulated:

### 2.1 Dependency Projections (`pubspec.yaml`)
To satisfy the requirements of Milestone 2, we need the following packages added to `dependencies` in `pubspec.yaml`:
1.  **`http: ^1.3.0`**: Provides standard, lightweight HTTP requests. While a heavy library like `dio` offers complex features, `http` is ideal for isolate workers because it lacks heavy platform bindings, allowing it to compile and run efficiently in secondary Dart Isolates.
2.  **`path_provider: ^2.1.5`**: Required for locating safe storage paths on Android/iOS/Windows (such as temp and application directories) for the chunks and final output.
3.  **`crypto: ^3.0.6`**: Required to compute SHA-256 checksums to verify downloaded file integrity.
4.  **`path: ^1.9.1`**: Vital for platform-independent manipulation of file paths (joining paths, extracts, extensions).

### 2.2 Download Splitter Class (`DownloadSplitter`)
Dart is fundamentally single-threaded, running inside an event loop. Real multi-threading requires Dart **Isolates**, which run on separate CPU cores and don't share memory.
*   **Avoid Write Contention**: If multiple Isolates try to write concurrently to a single file at different offsets, file-locking and position pointer conflicts will occur.
*   **Chunk Isolation Design**: The optimal solution is to write each range segment to its own temporary chunk file (e.g., `destination.part0`, `destination.part1`). Once all segments are finished, they are joined sequentially.
*   **Byte Range Calculations**:
    *   Pre-flight `HEAD` check requests the total content size ($S$) and verifies range support (`Accept-Ranges` or status code `206`).
    *   For $N$ segments, the block size is $B = S \text{ \textasciitilde{}/ } N$.
    *   For chunk $i \in [0, N-1]$:
        *   $\text{Start} = i \times B$
        *   $\text{End} = (i == N - 1) ? S - 1 : (i + 1) \times B - 1$
*   **Pause and Resume**:
    *   Before starting a chunk download, check if the corresponding temporary chunk file `<destination>.part<i>` already exists.
    *   Read its length $L$ in bytes.
    *   If $L \ge (\text{End} - \text{Start} + 1)$, that chunk is complete.
    *   Otherwise, resume the download by modifying the Range request header: `Range: bytes=(Start + L)-End` and appending the response stream to the chunk file.

### 2.3 Chunk Combiner / Merger (`ChunkCombiner`)
*   **Stream-Based Merging**: Loading entire chunk files into RAM during merging can cause Out-Of-Memory (OOM) crashes on large files. The combiner must stream bytes from each chunk file to the final destination file sequentially.
*   **Disk-Space Optimization**: To reduce the peak storage overhead during merging, the combiner should delete each chunk file immediately after appending it to the final file.
*   **Integrity Check**:
    *   Calculate SHA-256 of the merged file using a stream-based transformer (`crypto`'s `sha256.bind(file.openRead())`).
    *   Compare the result with the expected hash.

---

## 3. Caveats

*   **Non-Range Support**: Some servers or URLs (e.g., dynamic streams, redirect paths, or legacy systems) do not support HTTP Range requests. The downloader must dynamically check this during the pre-flight request and fallback to a single-connection, non-range download.
*   **Isolate Memory Boundary**: Data passed to/from Isolates is copied. We must pass small configuration structures (like paths and byte indices) instead of raw byte blocks.
*   **OS Storage Limits**: Merging files temporarily increases the required storage space. If the target file size is $X$, the maximum temporary disk footprint during merging is $2X$ (if files are not deleted on the fly) or $X + \text{Remaining Chunks}$ (if deleted on the fly).
*   **Interrupted Merging**: If the merge process is interrupted (e.g., power loss, app crash), the final file will be corrupt, and some deleted chunk files may be missing. The resume/restart logic must be able to detect this state (e.g. by checking if chunk files are missing but final file is incomplete) and re-download.

---

## 4. Conclusion

We recommend a design structured as follows:

### 4.1 Pubspec Dependencies
Append the following package definitions to `pubspec.yaml`:
```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  http: ^1.3.0
  path_provider: ^2.1.5
  crypto: ^3.0.6
  path: ^1.9.1
```

### 4.2 Class Outline: `DownloadSplitter`
```dart
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class DownloadSplitter {
  final String url;
  final String destinationPath;
  final String tempDir;
  final int numChunks;
  final void Function(double progress, double speedBytesPerSec)? onProgress;

  DownloadSplitter({
    required this.url,
    required this.destinationPath,
    required this.tempDir,
    this.numChunks = 4,
    this.onProgress,
  });

  /// Starts the multi-threaded download.
  Future<void> start() async {
    // 1. Perform pre-flight request to check content-length & range support
    // 2. Calculate byte range chunks
    // 3. Spawn workers using Isolate.run or Isolate.spawn
    // 4. Track progress through Ports or Future completions
  }

  /// Pauses the download.
  Future<void> pause() async {
    // Signal isolates to abort and close client connections
  }

  /// Cancels the download and cleans up chunks.
  Future<void> cancel() async {
    // Abort active connections and delete temporary files
  }
}
```

### 4.3 Class Outline: `ChunkCombiner`
```dart
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

class ChunkCombiner {
  final List<String> chunkPaths;
  final String destinationPath;
  final String? expectedSHA256;

  ChunkCombiner({
    required this.chunkPaths,
    required this.destinationPath,
    this.expectedSHA256,
  });

  /// Combines all chunk files in order and validates SHA-256.
  /// Returns true on success, false/throws on validation mismatch.
  Future<bool> mergeAndVerify() async {
    final finalFile = File(destinationPath);
    final sink = finalFile.openWrite(mode: FileMode.write);

    for (final path in chunkPaths) {
      final chunkFile = File(path);
      if (!await chunkFile.exists()) {
        throw Exception('Chunk file missing: $path');
      }
      
      // Stream chunks to final file
      await sink.addStream(chunkFile.openRead());
      
      // Delete chunk file immediately after merge to save disk space
      await chunkFile.delete();
    }
    await sink.close();

    // Verify SHA-256 if expected hash is provided
    if (expectedSHA256 != null) {
      final actualHash = await _calculateSHA256(finalFile);
      if (actualHash.toLowerCase() != expectedSHA256!.toLowerCase()) {
        await finalFile.delete(); // Remove corrupted file
        throw Exception('SHA-256 hash mismatch! Expected: $expectedSHA256, Got: $actualHash');
      }
    }
    return true;
  }

  Future<String> _calculateSHA256(File file) async {
    final stream = file.openRead();
    final hash = await sha256.bind(stream).first;
    return hash.toString();
  }
}
```

---

## 5. Verification Method

### 5.1 Verification Commands
Since this is a design recommendation phase (read-only), code is not yet written. Once the Implementer writes the classes, verification should be conducted using standard unit testing:
*   **Command**: `flutter test test/downloader_test.dart`

### 5.2 Unit Test Targets
1.  **Range Calculation Test**: Assert that for total size $S$ and chunks $N$, ranges generated are contiguous, non-overlapping, and start at $0$ and end at $S-1$.
2.  **Mock HTTP Range Download Test**: Use `package:http/testing.dart` to mock server range requests:
    *   Verify request headers contain the correct range (e.g. `bytes=0-249`).
    *   Verify the isolate writes the segment to its corresponding `.part` file.
3.  **Resume Resiliency Test**:
    *   Create a partial `.part0` file with some bytes.
    *   Start splitter and verify the HTTP request Range header starts at the offset of the existing file size.
4.  **Combiner and Hash Verification Test**:
    *   Write 3 mock text chunk files containing "Hello ", "World", "!!!".
    *   Run `ChunkCombiner` to merge them.
    *   Verify the final file content is "Hello World!!!".
    *   Verify `ChunkCombiner` matches the expected SHA-256 of "Hello World!!!" (`68725bb2a4e21a5d625b5976b91176b971a8f946e3fb24aa66b59524f0c74bc3` in lowercase hex) and correctly throws on a mismatched hash.
