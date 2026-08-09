// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'Aurora Downloader';

  @override
  String get tabQueue => 'Загрузки';

  @override
  String get tabBrowser => 'Браузер';

  @override
  String get tabSettings => 'Настройки';

  @override
  String get tabStudio => 'Студия FFmpeg';

  @override
  String get tabSniffed => 'Панель медиа';

  @override
  String get settingsLanguage => 'Язык приложения';

  @override
  String get settingsLanguageDesc =>
      'Выберите язык интерфейса Aurora Downloader';

  @override
  String get systemDefault => 'Системный по умолчанию';

  @override
  String get darkMode => 'Темная тема';

  @override
  String get searchOrTypeUrl => 'Поиск или ввод URL...';

  @override
  String get download => 'Скачать';

  @override
  String get cancel => 'Отмена';

  @override
  String get delete => 'Удалить';

  @override
  String get pause => 'Пауза';

  @override
  String get resume => 'Продолжить';

  @override
  String get retry => 'Повторить';

  @override
  String get completed => 'Завершено';

  @override
  String get downloading => 'Загрузка';

  @override
  String get paused => 'Приостановлено';

  @override
  String get failed => 'Ошибка';

  @override
  String get clearAll => 'Очистить все';

  @override
  String get confirm => 'Подтвердить';

  @override
  String get save => 'Сохранить';

  @override
  String get about => 'О приложении';

  @override
  String get version => 'Версия';
}
