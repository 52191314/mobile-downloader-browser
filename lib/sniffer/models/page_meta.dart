class PageMeta {
  final String title;
  final int? videoWidth;
  final int? videoHeight;
  final String? structuredName;

  /// `og:image` / `twitter:image` for the current page, used as the fallback
  /// capture-row poster when a media element carries no `poster` of its own.
  /// Absolute `http`/`https` only — validated on the bridge before it lands
  /// here.
  final String? ogImage;

  const PageMeta({
    this.title = '',
    this.videoWidth,
    this.videoHeight,
    this.structuredName,
    this.ogImage,
  });
}
