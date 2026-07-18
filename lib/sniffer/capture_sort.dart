import '../settings/download_settings.dart';
import 'models/sniffed_media.dart';

/// Sorts sniffed media for the catch sheet according to [sort].
List<SniffedMedia> sortSniffedMedia(
  List<SniffedMedia> media,
  SniffedMediaSort sort,
) {
  final list = [...media];
  switch (sort) {
    case SniffedMediaSort.newest:
      list.sort((a, b) => b.sniffedAt.compareTo(a.sniffedAt));
      break;
    case SniffedMediaSort.name:
      list.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      break;
    case SniffedMediaSort.type:
      list.sort((a, b) => a.type.name.compareTo(b.type.name));
      break;
    case SniffedMediaSort.size:
      list.sort(
        (a, b) => (b.contentLengthBytes ?? -1).compareTo(
          a.contentLengthBytes ?? -1,
        ),
      );
      break;
    case SniffedMediaSort.duration:
      list.sort(
        (a, b) => (b.duration?.inMilliseconds ?? -1).compareTo(
          a.duration?.inMilliseconds ?? -1,
        ),
      );
      break;
  }
  return list;
}
