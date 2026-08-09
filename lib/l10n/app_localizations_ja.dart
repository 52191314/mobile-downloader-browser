// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'Aurora Downloader';

  @override
  String get tabQueue => 'ダウンロード';

  @override
  String get tabBrowser => 'ブラウザ';

  @override
  String get tabSettings => '設定';

  @override
  String get tabStudio => 'FFmpeg スタジオ';

  @override
  String get tabSniffed => 'メディアトレイ';

  @override
  String get settingsLanguage => 'アプリの言語';

  @override
  String get settingsLanguageDesc => 'Aurora Downloader の表示言語を選択します';

  @override
  String get systemDefault => 'システムデフォルト';

  @override
  String get darkMode => 'ダークモード';

  @override
  String get searchOrTypeUrl => '検索またはURLを入力...';

  @override
  String get download => 'ダウンロード';

  @override
  String get cancel => 'キャンセル';

  @override
  String get delete => '削除';

  @override
  String get pause => '一時停止';

  @override
  String get resume => '再開';

  @override
  String get retry => '再試行';

  @override
  String get completed => '完了';

  @override
  String get downloading => 'ダウンロード中';

  @override
  String get paused => '一時停止中';

  @override
  String get failed => '失敗';

  @override
  String get clearAll => 'すべて消去';

  @override
  String get confirm => '確認';

  @override
  String get save => '保存';

  @override
  String get about => 'アプリについて';

  @override
  String get version => 'バージョン';
}
