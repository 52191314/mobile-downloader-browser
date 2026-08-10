/// Compile-time distribution channel for Aurora Play Store builds.
class BuildChannel {
  BuildChannel._();

  /// Google Play Store build. Always true in this repository.
  static const bool isPlay = true;

  /// Sideload / open-source channel. Always false in this repository.
  static const bool isGithub = false;

  static const String label = 'play';
}
