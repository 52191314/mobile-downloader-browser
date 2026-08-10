import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_hi.dart';
import 'app_localizations_id.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_pt.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('hi'),
    Locale('id'),
    Locale('ja'),
    Locale('pt'),
    Locale('ru'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Aurora Downloader'**
  String get appTitle;

  /// No description provided for @tabQueue.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get tabQueue;

  /// No description provided for @tabBrowser.
  ///
  /// In en, this message translates to:
  /// **'Browser'**
  String get tabBrowser;

  /// No description provided for @tabSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tabSettings;

  /// No description provided for @tabStudio.
  ///
  /// In en, this message translates to:
  /// **'FFmpeg Studio'**
  String get tabStudio;

  /// No description provided for @tabSniffed.
  ///
  /// In en, this message translates to:
  /// **'Media Tray'**
  String get tabSniffed;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'App Language'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageDesc.
  ///
  /// In en, this message translates to:
  /// **'Choose the display language for Aurora Downloader interface'**
  String get settingsLanguageDesc;

  /// No description provided for @systemDefault.
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get systemDefault;

  /// No description provided for @darkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark Mode'**
  String get darkMode;

  /// No description provided for @searchOrTypeUrl.
  ///
  /// In en, this message translates to:
  /// **'Search or type URL...'**
  String get searchOrTypeUrl;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @resume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get resume;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @completed.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get completed;

  /// No description provided for @downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get downloading;

  /// No description provided for @paused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get paused;

  /// No description provided for @failed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get failed;

  /// No description provided for @clearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear All'**
  String get clearAll;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @onboardingWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'App Language'**
  String get onboardingWelcomeTitle;

  /// No description provided for @onboardingWelcomeDesc.
  ///
  /// In en, this message translates to:
  /// **'Select your display language for Aurora Downloader interface:'**
  String get onboardingWelcomeDesc;

  /// No description provided for @onboardingContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get onboardingContinue;

  /// No description provided for @onboardingStep1Title.
  ///
  /// In en, this message translates to:
  /// **'Link & URL Input'**
  String get onboardingStep1Title;

  /// No description provided for @onboardingStep1Desc.
  ///
  /// In en, this message translates to:
  /// **'Paste media URLs or stream links here to start a download without opening the browser.'**
  String get onboardingStep1Desc;

  /// No description provided for @onboardingStep2Title.
  ///
  /// In en, this message translates to:
  /// **'Media Sniffer Browser'**
  String get onboardingStep2Title;

  /// No description provided for @onboardingStep2Desc.
  ///
  /// In en, this message translates to:
  /// **'Open the built-in browser to browse sites and auto-detect streams, HLS playlists, and audio.'**
  String get onboardingStep2Desc;

  /// No description provided for @onboardingStep3Title.
  ///
  /// In en, this message translates to:
  /// **'Sniffed Media (Radar)'**
  String get onboardingStep3Title;

  /// No description provided for @onboardingStep3Desc.
  ///
  /// In en, this message translates to:
  /// **'When the radar lights up, tap it to review detected media and add items to the queue.'**
  String get onboardingStep3Desc;

  /// No description provided for @onboardingStep4Title.
  ///
  /// In en, this message translates to:
  /// **'Browser Tabs'**
  String get onboardingStep4Title;

  /// No description provided for @onboardingStep4Desc.
  ///
  /// In en, this message translates to:
  /// **'Manage multiple pages at once — open, switch, or close tabs from this control.'**
  String get onboardingStep4Desc;

  /// No description provided for @onboardingStep5Title.
  ///
  /// In en, this message translates to:
  /// **'Menu Popup (⋯)'**
  String get onboardingStep5Title;

  /// No description provided for @onboardingStep5Desc.
  ///
  /// In en, this message translates to:
  /// **'Opens Settings and Tools: User Guide, Adblock, Download Rules, Private Vault, and WebDAV Backup.'**
  String get onboardingStep5Desc;

  /// No description provided for @skipTutorial.
  ///
  /// In en, this message translates to:
  /// **'Skip tutorial'**
  String get skipTutorial;

  /// No description provided for @gotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it!'**
  String get gotIt;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @menuSegmentSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get menuSegmentSettings;

  /// No description provided for @menuSegmentTools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get menuSegmentTools;

  /// No description provided for @menuDefaults.
  ///
  /// In en, this message translates to:
  /// **'Defaults'**
  String get menuDefaults;

  /// No description provided for @menuNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get menuNetwork;

  /// No description provided for @menuRules.
  ///
  /// In en, this message translates to:
  /// **'Rules'**
  String get menuRules;

  /// No description provided for @menuSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get menuSchedule;

  /// No description provided for @menuAdblock.
  ///
  /// In en, this message translates to:
  /// **'Adblock'**
  String get menuAdblock;

  /// No description provided for @menuSearchPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Search & Privacy'**
  String get menuSearchPrivacy;

  /// No description provided for @menuSniffer.
  ///
  /// In en, this message translates to:
  /// **'Sniffer'**
  String get menuSniffer;

  /// No description provided for @menuTheme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get menuTheme;

  /// No description provided for @menuProfiles.
  ///
  /// In en, this message translates to:
  /// **'Profiles'**
  String get menuProfiles;

  /// No description provided for @menuExternalApps.
  ///
  /// In en, this message translates to:
  /// **'External apps'**
  String get menuExternalApps;

  /// No description provided for @menuBackup.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get menuBackup;

  /// No description provided for @menuGoogleDrive.
  ///
  /// In en, this message translates to:
  /// **'Google Drive'**
  String get menuGoogleDrive;

  /// No description provided for @menuWebdavBackup.
  ///
  /// In en, this message translates to:
  /// **'WebDAV Backup'**
  String get menuWebdavBackup;

  /// No description provided for @menuPrivateVault.
  ///
  /// In en, this message translates to:
  /// **'Private Vault'**
  String get menuPrivateVault;

  /// No description provided for @menuProUltra.
  ///
  /// In en, this message translates to:
  /// **'Aurora Pro & Ultra'**
  String get menuProUltra;

  /// No description provided for @menuWatcher.
  ///
  /// In en, this message translates to:
  /// **'Aurora Watcher'**
  String get menuWatcher;

  /// No description provided for @menuAutomationApi.
  ///
  /// In en, this message translates to:
  /// **'Automation API'**
  String get menuAutomationApi;

  /// No description provided for @menuUserGuide.
  ///
  /// In en, this message translates to:
  /// **'User Guide'**
  String get menuUserGuide;

  /// No description provided for @menuAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get menuAbout;

  /// No description provided for @toolStealthOn.
  ///
  /// In en, this message translates to:
  /// **'Stealth Mode: On'**
  String get toolStealthOn;

  /// No description provided for @toolStealthOff.
  ///
  /// In en, this message translates to:
  /// **'Stealth Mode: Off'**
  String get toolStealthOff;

  /// No description provided for @toolIncognitoOn.
  ///
  /// In en, this message translates to:
  /// **'Incognito: On'**
  String get toolIncognitoOn;

  /// No description provided for @toolIncognitoOff.
  ///
  /// In en, this message translates to:
  /// **'Incognito: Off'**
  String get toolIncognitoOff;

  /// No description provided for @toolCustomTab.
  ///
  /// In en, this message translates to:
  /// **'Open in Custom Tab'**
  String get toolCustomTab;

  /// No description provided for @toolHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get toolHistory;

  /// No description provided for @toolFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get toolFavorites;

  /// No description provided for @toolSavedPages.
  ///
  /// In en, this message translates to:
  /// **'Saved pages'**
  String get toolSavedPages;

  /// No description provided for @toolSavePage.
  ///
  /// In en, this message translates to:
  /// **'Save page'**
  String get toolSavePage;

  /// No description provided for @toolFindOnPage.
  ///
  /// In en, this message translates to:
  /// **'Find on page'**
  String get toolFindOnPage;

  /// No description provided for @toolAutofill.
  ///
  /// In en, this message translates to:
  /// **'Autofill'**
  String get toolAutofill;

  /// No description provided for @toolReaderMode.
  ///
  /// In en, this message translates to:
  /// **'Reader mode'**
  String get toolReaderMode;

  /// No description provided for @toolAdblockOn.
  ///
  /// In en, this message translates to:
  /// **'Adblock: On'**
  String get toolAdblockOn;

  /// No description provided for @toolAdblockOff.
  ///
  /// In en, this message translates to:
  /// **'Adblock: Off'**
  String get toolAdblockOff;

  /// No description provided for @toolAdsAllowed.
  ///
  /// In en, this message translates to:
  /// **'Ads allowed'**
  String get toolAdsAllowed;

  /// No description provided for @toolBlockElement.
  ///
  /// In en, this message translates to:
  /// **'Block element'**
  String get toolBlockElement;

  /// No description provided for @toolResetBlocks.
  ///
  /// In en, this message translates to:
  /// **'Reset blocks'**
  String get toolResetBlocks;

  /// No description provided for @toolRescanMedia.
  ///
  /// In en, this message translates to:
  /// **'Re-scan media'**
  String get toolRescanMedia;

  /// No description provided for @toolBatchDownload.
  ///
  /// In en, this message translates to:
  /// **'Download all on this page'**
  String get toolBatchDownload;

  /// No description provided for @toolClearCookies.
  ///
  /// In en, this message translates to:
  /// **'Clear cookies'**
  String get toolClearCookies;

  /// No description provided for @emptyQueueTitle.
  ///
  /// In en, this message translates to:
  /// **'No downloads yet'**
  String get emptyQueueTitle;

  /// No description provided for @emptyQueueDesc.
  ///
  /// In en, this message translates to:
  /// **'Paste a media URL above or use the Browser to find videos and files'**
  String get emptyQueueDesc;

  /// No description provided for @catCoreSettings.
  ///
  /// In en, this message translates to:
  /// **'Core Settings'**
  String get catCoreSettings;

  /// No description provided for @catPrivacySecurity.
  ///
  /// In en, this message translates to:
  /// **'Privacy & Security'**
  String get catPrivacySecurity;

  /// No description provided for @catCustomization.
  ///
  /// In en, this message translates to:
  /// **'Customization'**
  String get catCustomization;

  /// No description provided for @catBackupSync.
  ///
  /// In en, this message translates to:
  /// **'Backup & Sync'**
  String get catBackupSync;

  /// No description provided for @catAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get catAdvanced;

  /// No description provided for @pageTitleDefaults.
  ///
  /// In en, this message translates to:
  /// **'Download Defaults'**
  String get pageTitleDefaults;

  /// No description provided for @pageTitleNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network & Proxy'**
  String get pageTitleNetwork;

  /// No description provided for @pageTitleRules.
  ///
  /// In en, this message translates to:
  /// **'Download Rules'**
  String get pageTitleRules;

  /// No description provided for @pageTitleSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule Settings'**
  String get pageTitleSchedule;

  /// No description provided for @pageTitleAdblock.
  ///
  /// In en, this message translates to:
  /// **'Adblock & Filters'**
  String get pageTitleAdblock;

  /// No description provided for @pageTitleSearch.
  ///
  /// In en, this message translates to:
  /// **'Search & Privacy'**
  String get pageTitleSearch;

  /// No description provided for @pageTitleSniffer.
  ///
  /// In en, this message translates to:
  /// **'Media Sniffer'**
  String get pageTitleSniffer;

  /// No description provided for @pageTitleTheme.
  ///
  /// In en, this message translates to:
  /// **'Appearance & Theme'**
  String get pageTitleTheme;

  /// No description provided for @pageTitleProfiles.
  ///
  /// In en, this message translates to:
  /// **'User Profiles'**
  String get pageTitleProfiles;

  /// No description provided for @pageTitleExternalApps.
  ///
  /// In en, this message translates to:
  /// **'External Applications'**
  String get pageTitleExternalApps;

  /// No description provided for @pageTitleBackup.
  ///
  /// In en, this message translates to:
  /// **'Backup & Restore'**
  String get pageTitleBackup;

  /// No description provided for @pageTitleWebdav.
  ///
  /// In en, this message translates to:
  /// **'WebDAV Backup'**
  String get pageTitleWebdav;

  /// No description provided for @pageTitleVault.
  ///
  /// In en, this message translates to:
  /// **'Private Vault'**
  String get pageTitleVault;

  /// No description provided for @pageTitleWatcher.
  ///
  /// In en, this message translates to:
  /// **'Aurora Watcher'**
  String get pageTitleWatcher;

  /// No description provided for @pageTitleAutomation.
  ///
  /// In en, this message translates to:
  /// **'Automation API'**
  String get pageTitleAutomation;

  /// No description provided for @pageTitleUserGuide.
  ///
  /// In en, this message translates to:
  /// **'User Guide'**
  String get pageTitleUserGuide;

  /// No description provided for @pageTitleAbout.
  ///
  /// In en, this message translates to:
  /// **'About Aurora'**
  String get pageTitleAbout;

  /// No description provided for @sheetHistory.
  ///
  /// In en, this message translates to:
  /// **'Browsing History'**
  String get sheetHistory;

  /// No description provided for @sheetFavorites.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks & Favorites'**
  String get sheetFavorites;

  /// No description provided for @sheetSavedPages.
  ///
  /// In en, this message translates to:
  /// **'Saved Offline Pages'**
  String get sheetSavedPages;

  /// No description provided for @sheetTabs.
  ///
  /// In en, this message translates to:
  /// **'Tabs Manager'**
  String get sheetTabs;

  /// No description provided for @sheetSniffedMedia.
  ///
  /// In en, this message translates to:
  /// **'Detected Media'**
  String get sheetSniffedMedia;

  /// No description provided for @sheetDownloadPrompt.
  ///
  /// In en, this message translates to:
  /// **'Download Options'**
  String get sheetDownloadPrompt;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get actionConfirm;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @actionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get actionDelete;

  /// No description provided for @actionDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get actionDownload;

  /// No description provided for @actionShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get actionShare;

  /// No description provided for @actionOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get actionOpen;

  /// No description provided for @actionPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get actionPause;

  /// No description provided for @actionResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get actionResume;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get actionRetry;

  /// No description provided for @actionClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get actionClear;

  /// No description provided for @actionSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select All'**
  String get actionSelectAll;

  /// No description provided for @actionDeselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect All'**
  String get actionDeselectAll;

  /// No description provided for @actionPauseAll.
  ///
  /// In en, this message translates to:
  /// **'Pause All'**
  String get actionPauseAll;

  /// No description provided for @actionResumeAll.
  ///
  /// In en, this message translates to:
  /// **'Resume All'**
  String get actionResumeAll;

  /// No description provided for @actionClearCompleted.
  ///
  /// In en, this message translates to:
  /// **'Clear Completed'**
  String get actionClearCompleted;

  /// No description provided for @toastLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied to clipboard'**
  String get toastLinkCopied;

  /// No description provided for @toastDownloadEnqueued.
  ///
  /// In en, this message translates to:
  /// **'Download added to queue'**
  String get toastDownloadEnqueued;

  /// No description provided for @toastDownloadStarted.
  ///
  /// In en, this message translates to:
  /// **'Download started'**
  String get toastDownloadStarted;

  /// No description provided for @toastDownloadPaused.
  ///
  /// In en, this message translates to:
  /// **'Download paused'**
  String get toastDownloadPaused;

  /// No description provided for @toastDownloadCompleted.
  ///
  /// In en, this message translates to:
  /// **'Download finished'**
  String get toastDownloadCompleted;

  /// No description provided for @toastDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get toastDownloadFailed;

  /// No description provided for @notifDownloadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloading Media'**
  String get notifDownloadingTitle;

  /// No description provided for @notifCompleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Download Complete'**
  String get notifCompleteTitle;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'ar',
    'de',
    'en',
    'es',
    'hi',
    'id',
    'ja',
    'pt',
    'ru',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'hi':
      return AppLocalizationsHi();
    case 'id':
      return AppLocalizationsId();
    case 'ja':
      return AppLocalizationsJa();
    case 'pt':
      return AppLocalizationsPt();
    case 'ru':
      return AppLocalizationsRu();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
