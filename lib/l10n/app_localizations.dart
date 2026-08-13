import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
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
    Locale('fr'),
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

  /// No description provided for @lblMaxConcurrentDownloads.
  ///
  /// In en, this message translates to:
  /// **'Max concurrent downloads'**
  String get lblMaxConcurrentDownloads;

  /// No description provided for @lblChunksPerDownload.
  ///
  /// In en, this message translates to:
  /// **'Chunks per download'**
  String get lblChunksPerDownload;

  /// No description provided for @lblDownloadDestination.
  ///
  /// In en, this message translates to:
  /// **'Destination (under Downloads)'**
  String get lblDownloadDestination;

  /// No description provided for @lblAutoRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Auto-retry failed downloads'**
  String get lblAutoRetryFailed;

  /// No description provided for @lblRetryLimit.
  ///
  /// In en, this message translates to:
  /// **'Retry limit'**
  String get lblRetryLimit;

  /// No description provided for @lblAutoClassify.
  ///
  /// In en, this message translates to:
  /// **'Auto-classify downloads'**
  String get lblAutoClassify;

  /// No description provided for @lblAutoClassifyDesc.
  ///
  /// In en, this message translates to:
  /// **'Sort finished files into Videos, Audio, Images, Documents when they land in Downloads.'**
  String get lblAutoClassifyDesc;

  /// No description provided for @lblConvertTsToMp4.
  ///
  /// In en, this message translates to:
  /// **'Convert .ts to .mp4'**
  String get lblConvertTsToMp4;

  /// No description provided for @lblConvertTsToMp4Desc.
  ///
  /// In en, this message translates to:
  /// **'After download, Aurora remuxes MPEG-TS (.ts) — including HLS — to .mp4 so files play in any app. Turn off to keep the original .ts.'**
  String get lblConvertTsToMp4Desc;

  /// No description provided for @lblIncludeQualitySuffix.
  ///
  /// In en, this message translates to:
  /// **'Include quality suffix'**
  String get lblIncludeQualitySuffix;

  /// No description provided for @lblIncludeQualitySuffixDesc.
  ///
  /// In en, this message translates to:
  /// **'Appends \" (720p)\" etc. to filenames when a resolution is detected.'**
  String get lblIncludeQualitySuffixDesc;

  /// No description provided for @lblMaxDetectedMedia.
  ///
  /// In en, this message translates to:
  /// **'Max detected media'**
  String get lblMaxDetectedMedia;

  /// No description provided for @lblDownloadLinkBehavior.
  ///
  /// In en, this message translates to:
  /// **'Download link behavior'**
  String get lblDownloadLinkBehavior;

  /// No description provided for @lblWifiOnly.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi only downloads'**
  String get lblWifiOnly;

  /// No description provided for @lblWifiOnlyDescOn.
  ///
  /// In en, this message translates to:
  /// **'Downloads only proceed on Wi-Fi. Turn off to use mobile data.'**
  String get lblWifiOnlyDescOn;

  /// No description provided for @lblWifiOnlyDescOff.
  ///
  /// In en, this message translates to:
  /// **'Enable to restrict downloads to Wi-Fi networks.'**
  String get lblWifiOnlyDescOff;

  /// No description provided for @lblProStallControls.
  ///
  /// In en, this message translates to:
  /// **'Pro: Advanced stall controls'**
  String get lblProStallControls;

  /// No description provided for @lblStallTimeout.
  ///
  /// In en, this message translates to:
  /// **'Stall timeout (seconds)'**
  String get lblStallTimeout;

  /// No description provided for @lblMinSpeedThreshold.
  ///
  /// In en, this message translates to:
  /// **'Min speed threshold (KB/s)'**
  String get lblMinSpeedThreshold;

  /// No description provided for @lblPartialMergeThreshold.
  ///
  /// In en, this message translates to:
  /// **'Partial download merge threshold'**
  String get lblPartialMergeThreshold;

  /// No description provided for @lblAdvancedStallControls.
  ///
  /// In en, this message translates to:
  /// **'Advanced stall controls'**
  String get lblAdvancedStallControls;

  /// No description provided for @lblAdvancedStallDesc.
  ///
  /// In en, this message translates to:
  /// **'Stall timeout, speed threshold, and partial merge (Pro)'**
  String get lblAdvancedStallDesc;

  /// No description provided for @lblSpeedLimit.
  ///
  /// In en, this message translates to:
  /// **'Speed limit'**
  String get lblSpeedLimit;

  /// No description provided for @lblSpeedLimitHelp.
  ///
  /// In en, this message translates to:
  /// **'Set to 0 for no limit, or drag right to cap speed (up to 500 MB/s)'**
  String get lblSpeedLimitHelp;

  /// No description provided for @lblUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get lblUnlimited;

  /// No description provided for @lblAdblockHeader.
  ///
  /// In en, this message translates to:
  /// **'Adblock'**
  String get lblAdblockHeader;

  /// No description provided for @lblEnableAdblock.
  ///
  /// In en, this message translates to:
  /// **'Enable adblock'**
  String get lblEnableAdblock;

  /// No description provided for @lblBlockPopups.
  ///
  /// In en, this message translates to:
  /// **'Block popups'**
  String get lblBlockPopups;

  /// No description provided for @lblBlockPopupsDescOn.
  ///
  /// In en, this message translates to:
  /// **'Block popups Aurora didn\'t expect. Turn off to allow sites to open popups.'**
  String get lblBlockPopupsDescOn;

  /// No description provided for @lblBlockPopupsDescOff.
  ///
  /// In en, this message translates to:
  /// **'Let sites open popups when you tap a link. Turn on to block unexpected ones.'**
  String get lblBlockPopupsDescOff;

  /// No description provided for @lblBlockInvisibleRedirects.
  ///
  /// In en, this message translates to:
  /// **'Block invisible redirects'**
  String get lblBlockInvisibleRedirects;

  /// No description provided for @lblBlockInvisibleRedirectsDescOn.
  ///
  /// In en, this message translates to:
  /// **'Intercept redirects and ask before navigating. Use this to avoid being sent to unexpected pages.'**
  String get lblBlockInvisibleRedirectsDescOn;

  /// No description provided for @lblBlockInvisibleRedirectsDescOff.
  ///
  /// In en, this message translates to:
  /// **'Let redirects navigate without asking. Turn on if a site keeps sending you away.'**
  String get lblBlockInvisibleRedirectsDescOff;

  /// No description provided for @lblBlockTrackers.
  ///
  /// In en, this message translates to:
  /// **'Block trackers (Pro)'**
  String get lblBlockTrackers;

  /// No description provided for @lblBlockTrackersDescOn.
  ///
  /// In en, this message translates to:
  /// **'Block known tracker domains and analytics scripts. Requires Aurora Pro.'**
  String get lblBlockTrackersDescOn;

  /// No description provided for @lblBlockTrackersDescOff.
  ///
  /// In en, this message translates to:
  /// **'Block known tracker domains. Pro feature.'**
  String get lblBlockTrackersDescOff;

  /// No description provided for @lblPerSiteAllowlist.
  ///
  /// In en, this message translates to:
  /// **'Per-site allowlist'**
  String get lblPerSiteAllowlist;

  /// No description provided for @lblPerSiteAllowlistEmpty.
  ///
  /// In en, this message translates to:
  /// **'No sites are allowlisted. Tap the shield in the browser toolbar to allowlist a site.'**
  String get lblPerSiteAllowlistEmpty;

  /// No description provided for @lblEnableAll.
  ///
  /// In en, this message translates to:
  /// **'Enable all'**
  String get lblEnableAll;

  /// No description provided for @lblDisableAll.
  ///
  /// In en, this message translates to:
  /// **'Disable all'**
  String get lblDisableAll;

  /// No description provided for @lblAddCustomFilterUrl.
  ///
  /// In en, this message translates to:
  /// **'Add custom filter URL'**
  String get lblAddCustomFilterUrl;

  /// No description provided for @lblCustomFilterUrlsPro.
  ///
  /// In en, this message translates to:
  /// **'Custom filter URLs (Pro only)'**
  String get lblCustomFilterUrlsPro;

  /// No description provided for @lblBlockedElementsSite.
  ///
  /// In en, this message translates to:
  /// **'Blocked elements by site'**
  String get lblBlockedElementsSite;

  /// No description provided for @lblNoBlockedElements.
  ///
  /// In en, this message translates to:
  /// **'No elements or hosts manually blocked.'**
  String get lblNoBlockedElements;

  /// No description provided for @lblPrivateBrowsingHeader.
  ///
  /// In en, this message translates to:
  /// **'Private Browsing'**
  String get lblPrivateBrowsingHeader;

  /// No description provided for @lblIncognitoMode.
  ///
  /// In en, this message translates to:
  /// **'Private / Incognito mode'**
  String get lblIncognitoMode;

  /// No description provided for @lblIncognitoModeDescOn.
  ///
  /// In en, this message translates to:
  /// **'Private mode is ON. History and cookies are suppressed. Active tabs show a purple shield.'**
  String get lblIncognitoModeDescOn;

  /// No description provided for @lblIncognitoModeDescOff.
  ///
  /// In en, this message translates to:
  /// **'Browse without saving history or cookies. Active tabs show a purple shield icon when private mode is ON.'**
  String get lblIncognitoModeDescOff;

  /// No description provided for @lblSearchEngineHeader.
  ///
  /// In en, this message translates to:
  /// **'Search Engine'**
  String get lblSearchEngineHeader;

  /// No description provided for @lblSearchEngine.
  ///
  /// In en, this message translates to:
  /// **'Search engine'**
  String get lblSearchEngine;

  /// No description provided for @lblCustomUrlTemplate.
  ///
  /// In en, this message translates to:
  /// **'Custom URL template (use %s for query)'**
  String get lblCustomUrlTemplate;

  /// No description provided for @lblInAppPlayerHeader.
  ///
  /// In en, this message translates to:
  /// **'In-app player'**
  String get lblInAppPlayerHeader;

  /// No description provided for @lblAutoOpenAuroraPlay.
  ///
  /// In en, this message translates to:
  /// **'Auto-open Aurora on site play'**
  String get lblAutoOpenAuroraPlay;

  /// No description provided for @lblAutoOpenAuroraPlayDescOn.
  ///
  /// In en, this message translates to:
  /// **'Tapping play on a page opens Aurora\'s player immediately (cookies/session preserved). Turn off to keep the site player and use the floating play icon instead.'**
  String get lblAutoOpenAuroraPlayDescOn;

  /// No description provided for @lblAutoOpenAuroraPlayDescOff.
  ///
  /// In en, this message translates to:
  /// **'Site players run normally. When Aurora sniffs a stream, a floating play icon appears over the video (like IDM) — tap it to open Aurora\'s player.'**
  String get lblAutoOpenAuroraPlayDescOff;

  /// No description provided for @lblPlaybackEngineHeader.
  ///
  /// In en, this message translates to:
  /// **'Playback engine'**
  String get lblPlaybackEngineHeader;

  /// No description provided for @lblPlaybackEngineDesc.
  ///
  /// In en, this message translates to:
  /// **'Which decoder plays video. If a stream loads but stays black or silent, switch engines — they use completely different decoders, so one often plays what the other cannot.'**
  String get lblPlaybackEngineDesc;

  /// No description provided for @lblEngineSystem.
  ///
  /// In en, this message translates to:
  /// **'System (ExoPlayer)'**
  String get lblEngineSystem;

  /// No description provided for @lblEngineSystemDesc.
  ///
  /// In en, this message translates to:
  /// **'Android\'s own player. Lightest on battery and memory.'**
  String get lblEngineSystemDesc;

  /// No description provided for @lblEngineMediaKit.
  ///
  /// In en, this message translates to:
  /// **'libmpv (media_kit)'**
  String get lblEngineMediaKit;

  /// No description provided for @lblEngineMediaKitDesc.
  ///
  /// In en, this message translates to:
  /// **'Bundled decoders. Handles streams ExoPlayer refuses.'**
  String get lblEngineMediaKitDesc;

  /// No description provided for @lblDisabledMediaTypes.
  ///
  /// In en, this message translates to:
  /// **'Disabled Media Types'**
  String get lblDisabledMediaTypes;

  /// No description provided for @lblExtraVideoHosts.
  ///
  /// In en, this message translates to:
  /// **'Extra Video Hosts'**
  String get lblExtraVideoHosts;

  /// No description provided for @lblExtraVideoHostsDesc.
  ///
  /// In en, this message translates to:
  /// **'Additional domains that serve video files. One host per line (e.g. example.com). URLs from these hosts are probed for video content.'**
  String get lblExtraVideoHostsDesc;

  /// No description provided for @lblAppearanceHeader.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get lblAppearanceHeader;

  /// No description provided for @lblDarkModePreference.
  ///
  /// In en, this message translates to:
  /// **'Dark mode preference'**
  String get lblDarkModePreference;

  /// No description provided for @lblSystemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get lblSystemDefault;

  /// No description provided for @lblLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get lblLight;

  /// No description provided for @lblDarkOled.
  ///
  /// In en, this message translates to:
  /// **'Dark (OLED black)'**
  String get lblDarkOled;

  /// No description provided for @lblAccentColorPack.
  ///
  /// In en, this message translates to:
  /// **'Accent color pack'**
  String get lblAccentColorPack;

  /// No description provided for @lblCompactQueue.
  ///
  /// In en, this message translates to:
  /// **'Compact queue items'**
  String get lblCompactQueue;

  /// No description provided for @lblCompactQueueDesc.
  ///
  /// In en, this message translates to:
  /// **'Display smaller download progress cards in the Queue view.'**
  String get lblCompactQueueDesc;

  /// No description provided for @lblHttpProxyHeader.
  ///
  /// In en, this message translates to:
  /// **'HTTP / SOCKS Proxy'**
  String get lblHttpProxyHeader;

  /// No description provided for @lblEnableProxy.
  ///
  /// In en, this message translates to:
  /// **'Enable proxy server'**
  String get lblEnableProxy;

  /// No description provided for @lblProxyServer.
  ///
  /// In en, this message translates to:
  /// **'Proxy Host & Port'**
  String get lblProxyServer;

  /// No description provided for @lblProxyType.
  ///
  /// In en, this message translates to:
  /// **'Proxy Type'**
  String get lblProxyType;

  /// No description provided for @lblUserAgentProfile.
  ///
  /// In en, this message translates to:
  /// **'User-Agent Profile'**
  String get lblUserAgentProfile;

  /// No description provided for @lblPerSiteUserAgents.
  ///
  /// In en, this message translates to:
  /// **'Per-site User-Agents'**
  String get lblPerSiteUserAgents;

  /// No description provided for @lblTlsSslCertificates.
  ///
  /// In en, this message translates to:
  /// **'Ignore TLS / SSL errors'**
  String get lblTlsSslCertificates;

  /// No description provided for @lblTlsSslCertificatesDesc.
  ///
  /// In en, this message translates to:
  /// **'Allows connecting to sites with invalid or self-signed HTTPS certificates.'**
  String get lblTlsSslCertificatesDesc;

  /// No description provided for @lblExportBackup.
  ///
  /// In en, this message translates to:
  /// **'Export Backup File'**
  String get lblExportBackup;

  /// No description provided for @lblImportBackup.
  ///
  /// In en, this message translates to:
  /// **'Import Backup File'**
  String get lblImportBackup;

  /// No description provided for @lblBackupDatabaseDesc.
  ///
  /// In en, this message translates to:
  /// **'Backup downloads, history, bookmarks, adblock filters, and app settings into a single file.'**
  String get lblBackupDatabaseDesc;

  /// No description provided for @lblRestoreDatabaseDesc.
  ///
  /// In en, this message translates to:
  /// **'Restore app data from a previously created backup file.'**
  String get lblRestoreDatabaseDesc;

  /// No description provided for @lblVaultTitle.
  ///
  /// In en, this message translates to:
  /// **'Private Vault'**
  String get lblVaultTitle;

  /// No description provided for @lblVaultDesc.
  ///
  /// In en, this message translates to:
  /// **'Store sensitive downloads and private files behind a PIN passcode or biometric lock.'**
  String get lblVaultDesc;

  /// No description provided for @lblSetPinPasscode.
  ///
  /// In en, this message translates to:
  /// **'Set PIN Passcode'**
  String get lblSetPinPasscode;

  /// No description provided for @lblChangePin.
  ///
  /// In en, this message translates to:
  /// **'Change PIN'**
  String get lblChangePin;

  /// No description provided for @lblUnlockVault.
  ///
  /// In en, this message translates to:
  /// **'Unlock Private Vault'**
  String get lblUnlockVault;

  /// No description provided for @lblEnterPin.
  ///
  /// In en, this message translates to:
  /// **'Enter 4-digit PIN'**
  String get lblEnterPin;

  /// No description provided for @lblFfmpegStudioTitle.
  ///
  /// In en, this message translates to:
  /// **'FFmpeg Studio'**
  String get lblFfmpegStudioTitle;

  /// No description provided for @lblRemuxVideo.
  ///
  /// In en, this message translates to:
  /// **'Remux Video'**
  String get lblRemuxVideo;

  /// No description provided for @lblExtractAudio.
  ///
  /// In en, this message translates to:
  /// **'Extract Audio (MP3 / AAC)'**
  String get lblExtractAudio;

  /// No description provided for @lblTrimCutVideo.
  ///
  /// In en, this message translates to:
  /// **'Trim / Cut Video'**
  String get lblTrimCutVideo;

  /// No description provided for @lblCompressVideo.
  ///
  /// In en, this message translates to:
  /// **'Compress Video'**
  String get lblCompressVideo;

  /// No description provided for @lblConvertFormat.
  ///
  /// In en, this message translates to:
  /// **'Convert Format'**
  String get lblConvertFormat;

  /// No description provided for @lblStartProcessing.
  ///
  /// In en, this message translates to:
  /// **'Start Processing'**
  String get lblStartProcessing;

  /// No description provided for @lblWatcherTitle.
  ///
  /// In en, this message translates to:
  /// **'Aurora Watcher'**
  String get lblWatcherTitle;

  /// No description provided for @lblClipboardMonitor.
  ///
  /// In en, this message translates to:
  /// **'Clipboard Monitor'**
  String get lblClipboardMonitor;

  /// No description provided for @lblClipboardMonitorDesc.
  ///
  /// In en, this message translates to:
  /// **'Automatically detect media links copied to your system clipboard and prompt to download.'**
  String get lblClipboardMonitorDesc;

  /// No description provided for @lblWebdavTitle.
  ///
  /// In en, this message translates to:
  /// **'WebDAV Backup'**
  String get lblWebdavTitle;

  /// No description provided for @lblServerUrl.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get lblServerUrl;

  /// No description provided for @lblUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get lblUsername;

  /// No description provided for @lblPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get lblPassword;

  /// No description provided for @lblTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test Connection'**
  String get lblTestConnection;

  /// No description provided for @lblSyncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync Now'**
  String get lblSyncNow;

  /// No description provided for @lblUserGuideTitle.
  ///
  /// In en, this message translates to:
  /// **'User Guide & Help'**
  String get lblUserGuideTitle;

  /// No description provided for @lblUserGuideDesc.
  ///
  /// In en, this message translates to:
  /// **'Learn how to capture streams, use private vault, configure adblock rules, and optimize download speed.'**
  String get lblUserGuideDesc;

  /// No description provided for @lblFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get lblFilterAll;

  /// No description provided for @lblFilterDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get lblFilterDownloading;

  /// No description provided for @lblFilterCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get lblFilterCompleted;

  /// No description provided for @lblFilterPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get lblFilterPaused;

  /// No description provided for @lblFilterFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get lblFilterFailed;

  /// No description provided for @lblPauseAll.
  ///
  /// In en, this message translates to:
  /// **'Pause All'**
  String get lblPauseAll;

  /// No description provided for @lblResumeAll.
  ///
  /// In en, this message translates to:
  /// **'Resume All'**
  String get lblResumeAll;

  /// No description provided for @lblClearCompleted.
  ///
  /// In en, this message translates to:
  /// **'Clear Completed'**
  String get lblClearCompleted;

  /// No description provided for @lblSearchQueue.
  ///
  /// In en, this message translates to:
  /// **'Search downloads...'**
  String get lblSearchQueue;

  /// No description provided for @cardPriorityHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get cardPriorityHigh;

  /// No description provided for @cardPriorityLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get cardPriorityLow;

  /// No description provided for @cardTooltipCancelScheduled.
  ///
  /// In en, this message translates to:
  /// **'Cancel scheduled'**
  String get cardTooltipCancelScheduled;

  /// No description provided for @cardTooltipPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get cardTooltipPause;

  /// No description provided for @cardTooltipResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get cardTooltipResume;

  /// No description provided for @cardTooltipRefreshLink.
  ///
  /// In en, this message translates to:
  /// **'Refresh link'**
  String get cardTooltipRefreshLink;

  /// No description provided for @cardTooltipRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get cardTooltipRetry;

  /// No description provided for @cardTooltipOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get cardTooltipOpen;

  /// No description provided for @cardMenuOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get cardMenuOpen;

  /// No description provided for @cardMenuShare.
  ///
  /// In en, this message translates to:
  /// **'Share…'**
  String get cardMenuShare;

  /// No description provided for @cardMenuSendToPc.
  ///
  /// In en, this message translates to:
  /// **'Send to PC…'**
  String get cardMenuSendToPc;

  /// No description provided for @cardMenuMoveToVault.
  ///
  /// In en, this message translates to:
  /// **'Move to Vault…'**
  String get cardMenuMoveToVault;

  /// No description provided for @cardMenuFfmpegStudio.
  ///
  /// In en, this message translates to:
  /// **'Edit in FFmpeg Studio'**
  String get cardMenuFfmpegStudio;

  /// No description provided for @cardMenuRedownload.
  ///
  /// In en, this message translates to:
  /// **'Redownload'**
  String get cardMenuRedownload;

  /// No description provided for @cardMenuForceMerge.
  ///
  /// In en, this message translates to:
  /// **'Force merge'**
  String get cardMenuForceMerge;

  /// No description provided for @cardMenuRefreshLink.
  ///
  /// In en, this message translates to:
  /// **'Refresh link'**
  String get cardMenuRefreshLink;

  /// No description provided for @cardMenuResniffOnPage.
  ///
  /// In en, this message translates to:
  /// **'Re-sniff on page'**
  String get cardMenuResniffOnPage;

  /// No description provided for @cardMenuOpenSourcePage.
  ///
  /// In en, this message translates to:
  /// **'Open source page'**
  String get cardMenuOpenSourcePage;

  /// No description provided for @cardMenuScheduleDownload.
  ///
  /// In en, this message translates to:
  /// **'Schedule download'**
  String get cardMenuScheduleDownload;

  /// No description provided for @cardMenuRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get cardMenuRemove;

  /// No description provided for @cardMenuCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cardMenuCancel;

  /// No description provided for @cardMenuProperties.
  ///
  /// In en, this message translates to:
  /// **'Properties'**
  String get cardMenuProperties;

  /// No description provided for @cardStatusStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get cardStatusStarting;

  /// No description provided for @cardStatusScheduled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled'**
  String get cardStatusScheduled;

  /// No description provided for @cardStatusPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get cardStatusPaused;

  /// No description provided for @cardStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get cardStatusFailed;

  /// No description provided for @cardStatusMerging.
  ///
  /// In en, this message translates to:
  /// **'Merging…'**
  String get cardStatusMerging;

  /// No description provided for @cardStatusDownloaded.
  ///
  /// In en, this message translates to:
  /// **'downloaded'**
  String get cardStatusDownloaded;

  /// No description provided for @cardStatusSaved.
  ///
  /// In en, this message translates to:
  /// **'saved'**
  String get cardStatusSaved;

  /// No description provided for @cardSegmentsLabel.
  ///
  /// In en, this message translates to:
  /// **'segs'**
  String get cardSegmentsLabel;

  /// No description provided for @propDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'File details'**
  String get propDialogTitle;

  /// No description provided for @propDialogFileName.
  ///
  /// In en, this message translates to:
  /// **'File name'**
  String get propDialogFileName;

  /// No description provided for @propDialogLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get propDialogLocation;

  /// No description provided for @propDialogDownloadLink.
  ///
  /// In en, this message translates to:
  /// **'Download link'**
  String get propDialogDownloadLink;

  /// No description provided for @propDialogSourcePage.
  ///
  /// In en, this message translates to:
  /// **'Source page'**
  String get propDialogSourcePage;

  /// No description provided for @propDialogClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get propDialogClose;

  /// No description provided for @queueTitle.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get queueTitle;

  /// No description provided for @queueSelected.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String queueSelected(int count);

  /// No description provided for @queueTooltipSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get queueTooltipSearch;

  /// No description provided for @queueTooltipCloseSearch.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get queueTooltipCloseSearch;

  /// No description provided for @queueTooltipSelect.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get queueTooltipSelect;

  /// No description provided for @queueTooltipBulkActions.
  ///
  /// In en, this message translates to:
  /// **'Bulk actions'**
  String get queueTooltipBulkActions;

  /// No description provided for @queueTooltipShowList.
  ///
  /// In en, this message translates to:
  /// **'Show as list'**
  String get queueTooltipShowList;

  /// No description provided for @queueTooltipShowGrid.
  ///
  /// In en, this message translates to:
  /// **'Completed history grid'**
  String get queueTooltipShowGrid;

  /// No description provided for @queueSortBy.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get queueSortBy;

  /// No description provided for @queueResetFilters.
  ///
  /// In en, this message translates to:
  /// **'Reset filters'**
  String get queueResetFilters;

  /// No description provided for @queueOpenBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open Browser'**
  String get queueOpenBrowser;

  /// No description provided for @queueBulkPauseAll.
  ///
  /// In en, this message translates to:
  /// **'Pause all active'**
  String get queueBulkPauseAll;

  /// No description provided for @queueBulkResumeAll.
  ///
  /// In en, this message translates to:
  /// **'Resume all paused'**
  String get queueBulkResumeAll;

  /// No description provided for @queueBulkRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry all failed'**
  String get queueBulkRetryFailed;

  /// No description provided for @queueBulkCancelScheduled.
  ///
  /// In en, this message translates to:
  /// **'Cancel scheduled'**
  String get queueBulkCancelScheduled;

  /// No description provided for @queueBulkCancelActive.
  ///
  /// In en, this message translates to:
  /// **'Cancel active'**
  String get queueBulkCancelActive;

  /// No description provided for @queueBulkFindDuplicates.
  ///
  /// In en, this message translates to:
  /// **'Find duplicates'**
  String get queueBulkFindDuplicates;

  /// No description provided for @queueDlgCancelScheduledTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel scheduled downloads?'**
  String get queueDlgCancelScheduledTitle;

  /// No description provided for @queueDlgCancelActiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel active downloads?'**
  String get queueDlgCancelActiveTitle;

  /// No description provided for @queueDlgKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep'**
  String get queueDlgKeep;

  /// No description provided for @queueDlgRemoveAll.
  ///
  /// In en, this message translates to:
  /// **'Remove all'**
  String get queueDlgRemoveAll;

  /// No description provided for @queueDlgRemoveSelected.
  ///
  /// In en, this message translates to:
  /// **'Remove selected downloads?'**
  String get queueDlgRemoveSelected;

  /// No description provided for @queueDlgDuplicatesTitle.
  ///
  /// In en, this message translates to:
  /// **'Duplicate URLs'**
  String get queueDlgDuplicatesTitle;

  /// No description provided for @queueDlgNoDuplicates.
  ///
  /// In en, this message translates to:
  /// **'All tasks in the queue have unique URLs.'**
  String get queueDlgNoDuplicates;

  /// No description provided for @queueDlgClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get queueDlgClose;

  /// No description provided for @queueSnackEnterUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter a URL to schedule.'**
  String get queueSnackEnterUrl;

  /// No description provided for @queueSnackDownloadScheduled.
  ///
  /// In en, this message translates to:
  /// **'Download scheduled.'**
  String get queueSnackDownloadScheduled;

  /// No description provided for @queueSnackFileMissing.
  ///
  /// In en, this message translates to:
  /// **'File path is missing or file does not exist.'**
  String get queueSnackFileMissing;

  /// No description provided for @queueSnackFfmpegDownloading.
  ///
  /// In en, this message translates to:
  /// **'FFmpeg module is already downloading.'**
  String get queueSnackFfmpegDownloading;

  /// No description provided for @queueSnackFfmpegReady.
  ///
  /// In en, this message translates to:
  /// **'FFmpeg tools ready.'**
  String get queueSnackFfmpegReady;

  /// No description provided for @queueDlgFfmpegTitle.
  ///
  /// In en, this message translates to:
  /// **'Download FFmpeg tools?'**
  String get queueDlgFfmpegTitle;

  /// No description provided for @queueDlgFfmpegFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get queueDlgFfmpegFailedTitle;

  /// No description provided for @queueDlgDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get queueDlgDownload;

  /// No description provided for @queueDlgRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get queueDlgRetry;

  /// No description provided for @queueDlgSavePartialTitle.
  ///
  /// In en, this message translates to:
  /// **'Save partial file?'**
  String get queueDlgSavePartialTitle;

  /// No description provided for @queueDlgDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get queueDlgDismiss;

  /// No description provided for @queueDlgMergeAndSave.
  ///
  /// In en, this message translates to:
  /// **'Merge and save'**
  String get queueDlgMergeAndSave;

  /// No description provided for @queueDlgLinkAlreadyQueuedTitle.
  ///
  /// In en, this message translates to:
  /// **'Link already queued'**
  String get queueDlgLinkAlreadyQueuedTitle;

  /// No description provided for @queueDlgCreateNew.
  ///
  /// In en, this message translates to:
  /// **'Create new'**
  String get queueDlgCreateNew;

  /// No description provided for @queueSnackNewDownloadCreated.
  ///
  /// In en, this message translates to:
  /// **'Done - New download created with refreshed link.'**
  String get queueSnackNewDownloadCreated;

  /// No description provided for @snifferSnackCloudflareRetrying.
  ///
  /// In en, this message translates to:
  /// **'Cloudflare block detected — re-applying stealth & retrying…'**
  String get snifferSnackCloudflareRetrying;

  /// No description provided for @snifferCfTitle.
  ///
  /// In en, this message translates to:
  /// **'Cloudflare Blocked {host}'**
  String snifferCfTitle(String host);

  /// No description provided for @snifferCfDesc.
  ///
  /// In en, this message translates to:
  /// **'This site blocks in-app Android WebViews. Full browsers like Chrome bypass this block.'**
  String get snifferCfDesc;

  /// No description provided for @snifferCfAlreadyExternal.
  ///
  /// In en, this message translates to:
  /// **'This site is set to always open in Chrome Custom Tab.'**
  String get snifferCfAlreadyExternal;

  /// No description provided for @snifferCfClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get snifferCfClose;

  /// No description provided for @snifferCfOpenCct.
  ///
  /// In en, this message translates to:
  /// **'Open in Chrome Custom Tab'**
  String get snifferCfOpenCct;

  /// No description provided for @snifferCfOpenSystem.
  ///
  /// In en, this message translates to:
  /// **'Open in System Browser'**
  String get snifferCfOpenSystem;

  /// No description provided for @snifferCfAlwaysCct.
  ///
  /// In en, this message translates to:
  /// **'Always open {host} in Custom Tab'**
  String snifferCfAlwaysCct(String host);

  /// No description provided for @snifferSnackElementBlocked.
  ///
  /// In en, this message translates to:
  /// **'Element blocked. Undo?'**
  String get snifferSnackElementBlocked;

  /// No description provided for @snifferDlgDownloadAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Download all on this page'**
  String get snifferDlgDownloadAllTitle;

  /// No description provided for @snifferDlgCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get snifferDlgCancel;

  /// No description provided for @snifferDlgSiteDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Site Data'**
  String get snifferDlgSiteDataTitle;

  /// No description provided for @snifferDlgClearSiteData.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get snifferDlgClearSiteData;

  /// No description provided for @snifferSnackOpenPageFirst.
  ///
  /// In en, this message translates to:
  /// **'Open a page first to adjust adblock settings.'**
  String get snifferSnackOpenPageFirst;

  /// No description provided for @snifferAdblockTitle.
  ///
  /// In en, this message translates to:
  /// **'Adblock on this site'**
  String get snifferAdblockTitle;

  /// No description provided for @snifferAdblockBlockedCount.
  ///
  /// In en, this message translates to:
  /// **'Blocked {count} requests on this page'**
  String snifferAdblockBlockedCount(int count);

  /// No description provided for @snifferAdblockDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get snifferAdblockDone;

  /// No description provided for @snifferUndoLabel.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get snifferUndoLabel;

  /// No description provided for @snifferCancelLabel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get snifferCancelLabel;

  /// No description provided for @snifferPopupBlockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Popup blocked by Aurora'**
  String get snifferPopupBlockedTitle;

  /// No description provided for @snifferRedirectBlockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Redirect blocked by Aurora'**
  String get snifferRedirectBlockedTitle;

  /// No description provided for @snifferProfilesTitle.
  ///
  /// In en, this message translates to:
  /// **'No profiles yet'**
  String get snifferProfilesTitle;

  /// No description provided for @snifferNewProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'New profile'**
  String get snifferNewProfileTitle;

  /// No description provided for @queueFlatList.
  ///
  /// In en, this message translates to:
  /// **'Flat list (no sections)'**
  String get queueFlatList;

  /// No description provided for @guideTitle.
  ///
  /// In en, this message translates to:
  /// **'User Guide'**
  String get guideTitle;

  /// No description provided for @guideSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search user guide…'**
  String get guideSearchHint;

  /// No description provided for @guideQuickStart.
  ///
  /// In en, this message translates to:
  /// **'Quick Start'**
  String get guideQuickStart;

  /// No description provided for @guideEngineProtocols.
  ///
  /// In en, this message translates to:
  /// **'Download Engine & Protocols'**
  String get guideEngineProtocols;

  /// No description provided for @guideQueueGestures.
  ///
  /// In en, this message translates to:
  /// **'Queue Page & Gestures'**
  String get guideQueueGestures;

  /// No description provided for @guideBrowserSniffer.
  ///
  /// In en, this message translates to:
  /// **'Built-in Browser & Sniffer'**
  String get guideBrowserSniffer;

  /// No description provided for @guideSiteProfiles.
  ///
  /// In en, this message translates to:
  /// **'Site Profiles & Batch Grabber'**
  String get guideSiteProfiles;

  /// No description provided for @guideSendToPc.
  ///
  /// In en, this message translates to:
  /// **'Send to PC (Wi-Fi Transfer)'**
  String get guideSendToPc;

  /// No description provided for @guideRulesAutoNaming.
  ///
  /// In en, this message translates to:
  /// **'Download Rules & Auto-Naming'**
  String get guideRulesAutoNaming;

  /// No description provided for @guideScheduleNight.
  ///
  /// In en, this message translates to:
  /// **'Schedule & Night-Mode Downloading'**
  String get guideScheduleNight;

  /// No description provided for @guideAdblockPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Ad Blocking & Privacy Engine'**
  String get guideAdblockPrivacy;

  /// No description provided for @guideCustomHosts.
  ///
  /// In en, this message translates to:
  /// **'Custom Video Hosts & Extensionless Probes'**
  String get guideCustomHosts;

  /// No description provided for @guideThemesAccent.
  ///
  /// In en, this message translates to:
  /// **'Themes & Accent Color Packs'**
  String get guideThemesAccent;

  /// No description provided for @guidePrivateVault.
  ///
  /// In en, this message translates to:
  /// **'Encrypted Private Vault'**
  String get guidePrivateVault;

  /// No description provided for @guideFfmpegStudio.
  ///
  /// In en, this message translates to:
  /// **'FFmpeg Studio'**
  String get guideFfmpegStudio;

  /// No description provided for @guideBackupTransfer.
  ///
  /// In en, this message translates to:
  /// **'Backup & Database Transfer'**
  String get guideBackupTransfer;

  /// No description provided for @guideWatcherRss.
  ///
  /// In en, this message translates to:
  /// **'Watcher (RSS & Page Monitor)'**
  String get guideWatcherRss;

  /// No description provided for @guideAutomationApi.
  ///
  /// In en, this message translates to:
  /// **'Automation API'**
  String get guideAutomationApi;

  /// No description provided for @guidePipMode.
  ///
  /// In en, this message translates to:
  /// **'Picture-in-Picture (PiP)'**
  String get guidePipMode;

  /// No description provided for @guideIncognitoMode.
  ///
  /// In en, this message translates to:
  /// **'Incognito / Private Mode'**
  String get guideIncognitoMode;

  /// No description provided for @guideBuildTiers.
  ///
  /// In en, this message translates to:
  /// **'Build Channels & Feature Tiers'**
  String get guideBuildTiers;

  /// No description provided for @guideTroubleshootingFaq.
  ///
  /// In en, this message translates to:
  /// **'Troubleshooting & FAQ'**
  String get guideTroubleshootingFaq;

  /// No description provided for @settingsProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get settingsProxy;

  /// No description provided for @settingsProxyNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get settingsProxyNone;

  /// No description provided for @settingsUserAgent.
  ///
  /// In en, this message translates to:
  /// **'User-Agent'**
  String get settingsUserAgent;

  /// No description provided for @settingsUaMobile.
  ///
  /// In en, this message translates to:
  /// **'Mobile (default)'**
  String get settingsUaMobile;

  /// No description provided for @settingsUaDesktopChrome.
  ///
  /// In en, this message translates to:
  /// **'Desktop Chrome'**
  String get settingsUaDesktopChrome;

  /// No description provided for @settingsUaDesktopFirefox.
  ///
  /// In en, this message translates to:
  /// **'Desktop Firefox'**
  String get settingsUaDesktopFirefox;

  /// No description provided for @settingsUaSafari.
  ///
  /// In en, this message translates to:
  /// **'Safari'**
  String get settingsUaSafari;

  /// No description provided for @settingsUaCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom User-Agent'**
  String get settingsUaCustom;

  /// No description provided for @settingsProfiles.
  ///
  /// In en, this message translates to:
  /// **'Profiles'**
  String get settingsProfiles;

  /// No description provided for @settingsScheduledDownloads.
  ///
  /// In en, this message translates to:
  /// **'Scheduled Downloads'**
  String get settingsScheduledDownloads;

  /// No description provided for @settingsAutomationApi.
  ///
  /// In en, this message translates to:
  /// **'Automation API'**
  String get settingsAutomationApi;

  /// No description provided for @settingsEnableAutomation.
  ///
  /// In en, this message translates to:
  /// **'Enable Automation API'**
  String get settingsEnableAutomation;

  /// No description provided for @settingsRegenerateToken.
  ///
  /// In en, this message translates to:
  /// **'Regenerate Token'**
  String get settingsRegenerateToken;

  /// No description provided for @settingsRegenerateTokenPrompt.
  ///
  /// In en, this message translates to:
  /// **'Regenerate Token?'**
  String get settingsRegenerateTokenPrompt;

  /// No description provided for @settingsAboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAboutTitle;

  /// No description provided for @settingsAboutDesc.
  ///
  /// In en, this message translates to:
  /// **'Android download manager with segmented downloads, streaming video, torrents, and in-browser media detection.'**
  String get settingsAboutDesc;

  /// No description provided for @settingsCheckBattery.
  ///
  /// In en, this message translates to:
  /// **'Check battery optimization on launch'**
  String get settingsCheckBattery;

  /// No description provided for @settingsCheckBatteryDesc.
  ///
  /// In en, this message translates to:
  /// **'Notify if background download optimizations are not configured'**
  String get settingsCheckBatteryDesc;

  /// No description provided for @settingsProRestored.
  ///
  /// In en, this message translates to:
  /// **'Aurora Pro restored.'**
  String get settingsProRestored;

  /// No description provided for @settingsSnackTray.
  ///
  /// In en, this message translates to:
  /// **'Save to tray. Aurora keeps a list so you can pick which to download later.'**
  String get settingsSnackTray;

  /// No description provided for @settingsSnackImmediate.
  ///
  /// In en, this message translates to:
  /// **'Download right away. Skip the tray and start fetching immediately.'**
  String get settingsSnackImmediate;

  /// No description provided for @settingsSnackAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask each time Aurora spots media. Best when you download a mix of stuff.'**
  String get settingsSnackAsk;

  /// No description provided for @settingsSnackBlock.
  ///
  /// In en, this message translates to:
  /// **'Block downloads from this site. Aurora will ignore every media URL.'**
  String get settingsSnackBlock;

  /// No description provided for @settingsDriveSync.
  ///
  /// In en, this message translates to:
  /// **'Google Drive Sync'**
  String get settingsDriveSync;

  /// No description provided for @settingsDriveUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Drive sync unavailable'**
  String get settingsDriveUnavailable;

  /// No description provided for @settingsSetFolder.
  ///
  /// In en, this message translates to:
  /// **'Set folder'**
  String get settingsSetFolder;

  /// No description provided for @settingsAutoUploadCompleted.
  ///
  /// In en, this message translates to:
  /// **'Auto upload completed files'**
  String get settingsAutoUploadCompleted;

  /// No description provided for @settingsSyncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get settingsSyncNow;

  /// No description provided for @settingsLinkDrive.
  ///
  /// In en, this message translates to:
  /// **'Link Google Drive'**
  String get settingsLinkDrive;

  /// No description provided for @settingsResetExtAppsPrompt.
  ///
  /// In en, this message translates to:
  /// **'Reset all external app choices?'**
  String get settingsResetExtAppsPrompt;

  /// No description provided for @settingsExtAppsResetDone.
  ///
  /// In en, this message translates to:
  /// **'All external app choices reset.'**
  String get settingsExtAppsResetDone;

  /// No description provided for @settingsExternalApps.
  ///
  /// In en, this message translates to:
  /// **'External Apps'**
  String get settingsExternalApps;

  /// No description provided for @settingsBackupBookmarks.
  ///
  /// In en, this message translates to:
  /// **'Favorites / Bookmarks'**
  String get settingsBackupBookmarks;

  /// No description provided for @settingsBackupHistory.
  ///
  /// In en, this message translates to:
  /// **'Web History'**
  String get settingsBackupHistory;

  /// No description provided for @settingsBackupSavedPages.
  ///
  /// In en, this message translates to:
  /// **'Saved Pages'**
  String get settingsBackupSavedPages;

  /// No description provided for @settingsBackupQueue.
  ///
  /// In en, this message translates to:
  /// **'Download History (Queue & Schedule)'**
  String get settingsBackupQueue;

  /// No description provided for @settingsBackupSettings.
  ///
  /// In en, this message translates to:
  /// **'App Settings'**
  String get settingsBackupSettings;

  /// No description provided for @settingsBackupSessions.
  ///
  /// In en, this message translates to:
  /// **'Browser Sessions & Open Tabs'**
  String get settingsBackupSessions;

  /// No description provided for @settingsBackupRules.
  ///
  /// In en, this message translates to:
  /// **'Download Rules & Organization'**
  String get settingsBackupRules;

  /// No description provided for @settingsBackupImport.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get settingsBackupImport;

  /// No description provided for @settingsBackupRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Backup & Restore'**
  String get settingsBackupRestoreTitle;

  /// No description provided for @settingsChooseBackupFile.
  ///
  /// In en, this message translates to:
  /// **'Choose backup file'**
  String get settingsChooseBackupFile;

  /// No description provided for @settingsAutoBackup.
  ///
  /// In en, this message translates to:
  /// **'Auto Backup'**
  String get settingsAutoBackup;

  /// No description provided for @settingsEnableAutoBackup.
  ///
  /// In en, this message translates to:
  /// **'Enable auto backup'**
  String get settingsEnableAutoBackup;

  /// No description provided for @settingsBackupNow.
  ///
  /// In en, this message translates to:
  /// **'Back up now'**
  String get settingsBackupNow;

  /// No description provided for @settingsRestoreBtn.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get settingsRestoreBtn;

  /// No description provided for @settingsRulesTitle.
  ///
  /// In en, this message translates to:
  /// **'Download Rules'**
  String get settingsRulesTitle;

  /// No description provided for @settingsAddRule.
  ///
  /// In en, this message translates to:
  /// **'Add Rule'**
  String get settingsAddRule;

  /// No description provided for @settingsCreateFirstRule.
  ///
  /// In en, this message translates to:
  /// **'Create your first rule'**
  String get settingsCreateFirstRule;

  /// No description provided for @settingsCategoryVideo.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get settingsCategoryVideo;

  /// No description provided for @settingsCategoryAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get settingsCategoryAudio;

  /// No description provided for @settingsCategoryHls.
  ///
  /// In en, this message translates to:
  /// **'HLS'**
  String get settingsCategoryHls;

  /// No description provided for @settingsCategoryImage.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get settingsCategoryImage;

  /// No description provided for @settingsRequireWifi.
  ///
  /// In en, this message translates to:
  /// **'Require Wi-Fi'**
  String get settingsRequireWifi;

  /// No description provided for @settingsRequireCharging.
  ///
  /// In en, this message translates to:
  /// **'Require charging'**
  String get settingsRequireCharging;

  /// No description provided for @settingsTimeWindow.
  ///
  /// In en, this message translates to:
  /// **'Time window'**
  String get settingsTimeWindow;

  /// No description provided for @settingsDeleteRulePrompt.
  ///
  /// In en, this message translates to:
  /// **'Delete Rule'**
  String get settingsDeleteRulePrompt;

  /// No description provided for @settingsDeleteProfilePrompt.
  ///
  /// In en, this message translates to:
  /// **'Delete Profile'**
  String get settingsDeleteProfilePrompt;

  /// No description provided for @settingsNoProfilesYet.
  ///
  /// In en, this message translates to:
  /// **'No profiles yet'**
  String get settingsNoProfilesYet;

  /// No description provided for @settingsAddFirstProfile.
  ///
  /// In en, this message translates to:
  /// **'Add your first profile'**
  String get settingsAddFirstProfile;

  /// No description provided for @settingsToolbarSlide1.
  ///
  /// In en, this message translates to:
  /// **'Slide 1 (default)'**
  String get settingsToolbarSlide1;

  /// No description provided for @settingsToolbarSlide2.
  ///
  /// In en, this message translates to:
  /// **'Slide 2 (swipe left)'**
  String get settingsToolbarSlide2;

  /// No description provided for @settingsResetToolbarDefault.
  ///
  /// In en, this message translates to:
  /// **'Reset toolbar to default'**
  String get settingsResetToolbarDefault;

  /// No description provided for @ffmpegCompressVideo.
  ///
  /// In en, this message translates to:
  /// **'Compress Video'**
  String get ffmpegCompressVideo;

  /// No description provided for @ffmpegTrimVideo.
  ///
  /// In en, this message translates to:
  /// **'Trim Video'**
  String get ffmpegTrimVideo;

  /// No description provided for @ffmpegExtractAudio.
  ///
  /// In en, this message translates to:
  /// **'Extract Audio'**
  String get ffmpegExtractAudio;

  /// No description provided for @ffmpegRemuxMp4.
  ///
  /// In en, this message translates to:
  /// **'Remux to MP4'**
  String get ffmpegRemuxMp4;

  /// No description provided for @ffmpegCreateGif.
  ///
  /// In en, this message translates to:
  /// **'Create GIF'**
  String get ffmpegCreateGif;

  /// No description provided for @ffmpegSourceFile.
  ///
  /// In en, this message translates to:
  /// **'Source file'**
  String get ffmpegSourceFile;

  /// No description provided for @ffmpegOperation.
  ///
  /// In en, this message translates to:
  /// **'Operation'**
  String get ffmpegOperation;

  /// No description provided for @ffmpegQueuedOps.
  ///
  /// In en, this message translates to:
  /// **'Queued operations'**
  String get ffmpegQueuedOps;

  /// No description provided for @vaultDeleteFromVault.
  ///
  /// In en, this message translates to:
  /// **'Delete from vault?'**
  String get vaultDeleteFromVault;

  /// No description provided for @vaultNothingToImport.
  ///
  /// In en, this message translates to:
  /// **'Nothing to import'**
  String get vaultNothingToImport;

  /// No description provided for @vaultImportTitle.
  ///
  /// In en, this message translates to:
  /// **'Import into Private Vault'**
  String get vaultImportTitle;

  /// No description provided for @vaultDeleteOriginal.
  ///
  /// In en, this message translates to:
  /// **'Delete original after encrypting'**
  String get vaultDeleteOriginal;

  /// No description provided for @vaultLockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Vault is locked'**
  String get vaultLockedTitle;

  /// No description provided for @vaultUnlockBtn.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get vaultUnlockBtn;

  /// No description provided for @vaultEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Vault is empty'**
  String get vaultEmptyTitle;

  /// No description provided for @vaultEmptyDesc.
  ///
  /// In en, this message translates to:
  /// **'Move downloaded files here to keep them private'**
  String get vaultEmptyDesc;

  /// No description provided for @vaultAddFiles.
  ///
  /// In en, this message translates to:
  /// **'Add files'**
  String get vaultAddFiles;

  /// No description provided for @watcherAddWatch.
  ///
  /// In en, this message translates to:
  /// **'Add Watch'**
  String get watcherAddWatch;

  /// No description provided for @watcherAddFirstWatch.
  ///
  /// In en, this message translates to:
  /// **'Add your first watch'**
  String get watcherAddFirstWatch;

  /// No description provided for @watcherCheckNow.
  ///
  /// In en, this message translates to:
  /// **'Check now'**
  String get watcherCheckNow;

  /// No description provided for @watcherRssFeed.
  ///
  /// In en, this message translates to:
  /// **'RSS Feed'**
  String get watcherRssFeed;

  /// No description provided for @watcherWebPage.
  ///
  /// In en, this message translates to:
  /// **'Web Page'**
  String get watcherWebPage;

  /// No description provided for @watcherDeleteRulePrompt.
  ///
  /// In en, this message translates to:
  /// **'Delete Watch Rule'**
  String get watcherDeleteRulePrompt;

  /// No description provided for @webdavServerUrl.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get webdavServerUrl;

  /// No description provided for @webdavUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get webdavUsername;

  /// No description provided for @webdavPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get webdavPassword;

  /// No description provided for @webdavUploadBackupNow.
  ///
  /// In en, this message translates to:
  /// **'Upload backup now'**
  String get webdavUploadBackupNow;

  /// No description provided for @webdavRemoteBackups.
  ///
  /// In en, this message translates to:
  /// **'Remote backups'**
  String get webdavRemoteBackups;

  /// No description provided for @webdavNoBackupsYet.
  ///
  /// In en, this message translates to:
  /// **'No backups yet. Tap the upload button to create one.'**
  String get webdavNoBackupsYet;

  /// No description provided for @tourWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Aurora Downloader'**
  String get tourWelcomeTitle;

  /// No description provided for @tourSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip tour'**
  String get tourSkip;

  /// No description provided for @tourNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get tourNext;

  /// No description provided for @tourDone.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get tourDone;

  /// No description provided for @playerRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get playerRetry;

  /// No description provided for @playerPipNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Picture-in-Picture is not available on this device.'**
  String get playerPipNotAvailable;

  /// No description provided for @playerOpenInBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open in browser'**
  String get playerOpenInBrowser;

  /// No description provided for @playerCopyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy video link'**
  String get playerCopyLink;

  /// No description provided for @playerCopiedLink.
  ///
  /// In en, this message translates to:
  /// **'Copied video link to clipboard'**
  String get playerCopiedLink;

  /// No description provided for @playerPip.
  ///
  /// In en, this message translates to:
  /// **'Picture-in-picture'**
  String get playerPip;

  /// No description provided for @playerAddFav.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get playerAddFav;

  /// No description provided for @playerMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get playerMore;

  /// No description provided for @playerDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get playerDownload;

  /// No description provided for @playerSpeed.
  ///
  /// In en, this message translates to:
  /// **'Playback speed'**
  String get playerSpeed;

  /// No description provided for @playerQuality.
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get playerQuality;

  /// No description provided for @playerAspectRatio.
  ///
  /// In en, this message translates to:
  /// **'Aspect ratio'**
  String get playerAspectRatio;

  /// No description provided for @dlgAlreadyInQueue.
  ///
  /// In en, this message translates to:
  /// **'Already in Queue'**
  String get dlgAlreadyInQueue;

  /// No description provided for @dlgCreateNew.
  ///
  /// In en, this message translates to:
  /// **'Create New'**
  String get dlgCreateNew;

  /// No description provided for @dlgUpdateExisting.
  ///
  /// In en, this message translates to:
  /// **'Update Existing'**
  String get dlgUpdateExisting;

  /// No description provided for @dlgDuplicateContent.
  ///
  /// In en, this message translates to:
  /// **'A download with this name already exists in the queue.\n\nFile: {filename}'**
  String dlgDuplicateContent(String filename);

  /// No description provided for @dlgSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get dlgSkip;

  /// No description provided for @dlgReplace.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get dlgReplace;

  /// No description provided for @dlgApplyToAll.
  ///
  /// In en, this message translates to:
  /// **'Apply to all duplicates'**
  String get dlgApplyToAll;

  /// No description provided for @dlgPhishingWarning.
  ///
  /// In en, this message translates to:
  /// **'Phishing suspected'**
  String get dlgPhishingWarning;

  /// No description provided for @dlgStaySafe.
  ///
  /// In en, this message translates to:
  /// **'Stay safe'**
  String get dlgStaySafe;

  /// No description provided for @dlgContinueAnyway.
  ///
  /// In en, this message translates to:
  /// **'Continue anyway'**
  String get dlgContinueAnyway;

  /// No description provided for @favCreateFolder.
  ///
  /// In en, this message translates to:
  /// **'Create folder'**
  String get favCreateFolder;

  /// No description provided for @favFolderName.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get favFolderName;

  /// No description provided for @favUnsorted.
  ///
  /// In en, this message translates to:
  /// **'Unsorted'**
  String get favUnsorted;

  /// No description provided for @favEditTags.
  ///
  /// In en, this message translates to:
  /// **'Edit tags'**
  String get favEditTags;

  /// No description provided for @favRemoveBookmark.
  ///
  /// In en, this message translates to:
  /// **'Remove bookmark'**
  String get favRemoveBookmark;

  /// No description provided for @favAddToFav.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get favAddToFav;

  /// No description provided for @favEditFav.
  ///
  /// In en, this message translates to:
  /// **'Edit favorite'**
  String get favEditFav;

  /// No description provided for @historySearch.
  ///
  /// In en, this message translates to:
  /// **'Search history…'**
  String get historySearch;

  /// No description provided for @historySelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get historySelectAll;

  /// No description provided for @historyDeleteSelected.
  ///
  /// In en, this message translates to:
  /// **'Delete selected'**
  String get historyDeleteSelected;

  /// No description provided for @historyCancelSelection.
  ///
  /// In en, this message translates to:
  /// **'Cancel selection'**
  String get historyCancelSelection;

  /// No description provided for @captureRescan.
  ///
  /// In en, this message translates to:
  /// **'Rescan page for new media'**
  String get captureRescan;

  /// No description provided for @captureGrabSeries.
  ///
  /// In en, this message translates to:
  /// **'Grab series (episode order)'**
  String get captureGrabSeries;

  /// No description provided for @captureSortDisplay.
  ///
  /// In en, this message translates to:
  /// **'Sort and display options'**
  String get captureSortDisplay;

  /// No description provided for @captureDetails.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get captureDetails;

  /// No description provided for @dockGoBack.
  ///
  /// In en, this message translates to:
  /// **'Go back'**
  String get dockGoBack;

  /// No description provided for @dockGoForward.
  ///
  /// In en, this message translates to:
  /// **'Go forward'**
  String get dockGoForward;

  /// No description provided for @dockSniffedMedia.
  ///
  /// In en, this message translates to:
  /// **'Sniffed media'**
  String get dockSniffedMedia;

  /// No description provided for @dockDownloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get dockDownloads;

  /// No description provided for @dockTabs.
  ///
  /// In en, this message translates to:
  /// **'Tabs'**
  String get dockTabs;

  /// No description provided for @dockHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get dockHome;

  /// No description provided for @dockBrowserTools.
  ///
  /// In en, this message translates to:
  /// **'Browser tools'**
  String get dockBrowserTools;

  /// No description provided for @dockHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get dockHistory;

  /// No description provided for @dockBookmarks.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get dockBookmarks;

  /// No description provided for @dockSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get dockSettings;

  /// No description provided for @btnFindInPage.
  ///
  /// In en, this message translates to:
  /// **'Find in page'**
  String get btnFindInPage;

  /// No description provided for @btnRenameFile.
  ///
  /// In en, this message translates to:
  /// **'Rename File'**
  String get btnRenameFile;

  /// No description provided for @btnNewTab.
  ///
  /// In en, this message translates to:
  /// **'New tab'**
  String get btnNewTab;

  /// No description provided for @btnCloseAllTabs.
  ///
  /// In en, this message translates to:
  /// **'Close all tabs'**
  String get btnCloseAllTabs;

  /// No description provided for @btnNotNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get btnNotNow;

  /// No description provided for @btnStopSharing.
  ///
  /// In en, this message translates to:
  /// **'Stop sharing'**
  String get btnStopSharing;

  /// No description provided for @addToDownloadQueue.
  ///
  /// In en, this message translates to:
  /// **'Add to Download Queue'**
  String get addToDownloadQueue;

  /// No description provided for @fromLabel.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get fromLabel;

  /// No description provided for @linkLabel.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get linkLabel;

  /// No description provided for @priorityLabel.
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get priorityLabel;

  /// No description provided for @cardPriorityMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get cardPriorityMedium;

  /// No description provided for @loadingQuality.
  ///
  /// In en, this message translates to:
  /// **'Loading quality options...'**
  String get loadingQuality;

  /// No description provided for @downloadLater.
  ///
  /// In en, this message translates to:
  /// **'Download later'**
  String get downloadLater;

  /// No description provided for @filenameLongWarning.
  ///
  /// In en, this message translates to:
  /// **'Filename is long and was auto-truncated to fit Android\'s {limit}-byte file-name limit. You can rename it, or keep this name.'**
  String filenameLongWarning(int limit);

  /// No description provided for @snifferDlgClearSiteDataHost.
  ///
  /// In en, this message translates to:
  /// **'Clear cookies, localStorage, and cache for {host}?'**
  String snifferDlgClearSiteDataHost(String host);

  /// No description provided for @snifferDlgClearSiteDataThis.
  ///
  /// In en, this message translates to:
  /// **'Clear cookies, localStorage, and cache for this site?'**
  String get snifferDlgClearSiteDataThis;

  /// No description provided for @settingsScheduledEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Add a download and choose \"Download later\" to schedule it here.'**
  String get settingsScheduledEmptyHint;
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
    'fr',
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
    case 'fr':
      return AppLocalizationsFr();
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
