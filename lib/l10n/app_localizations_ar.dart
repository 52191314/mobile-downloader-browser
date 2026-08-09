// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'Aurora Downloader';

  @override
  String get tabQueue => 'التنزيلات';

  @override
  String get tabBrowser => 'المتصفح';

  @override
  String get tabSettings => 'الإعدادات';

  @override
  String get tabStudio => 'استوديو FFmpeg';

  @override
  String get tabSniffed => 'صينية الوسائط';

  @override
  String get settingsLanguage => 'لغة التطبيق';

  @override
  String get settingsLanguageDesc => 'اختر لغة العرض لواجهة Aurora Downloader';

  @override
  String get systemDefault => 'الافتراضي للنظام';

  @override
  String get darkMode => 'الوضع الداكن';

  @override
  String get searchOrTypeUrl => 'ابحث أو اكتب عنوان URL...';

  @override
  String get download => 'تنزيل';

  @override
  String get cancel => 'إلغاء';

  @override
  String get delete => 'حذف';

  @override
  String get pause => 'إيقاف مؤقت';

  @override
  String get resume => 'استئناف';

  @override
  String get retry => 'إعادة المحاولة';

  @override
  String get completed => 'مكتمل';

  @override
  String get downloading => 'جارٍ التنزيل';

  @override
  String get paused => 'متوقف مؤقتاً';

  @override
  String get failed => 'فشل';

  @override
  String get clearAll => 'مسح الكل';

  @override
  String get confirm => 'تأكيد';

  @override
  String get save => 'حفظ';

  @override
  String get about => 'حول';

  @override
  String get version => 'الإصدار';
}
