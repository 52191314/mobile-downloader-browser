class ClosedTabSnapshot {
  final String url;
  final String? title;

  const ClosedTabSnapshot({required this.url, this.title});

  Map<String, dynamic> toJson() => {'url': url, 'title': title};
}
