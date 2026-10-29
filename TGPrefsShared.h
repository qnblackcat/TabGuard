#import <Foundation/Foundation.h>

//Plist handling shared by the tweak (inside Safari) and the settings bundle (inside Settings)

#define TGSettingsChangedNotification CFSTR("com.qn.tabguard.settingschanged")

FOUNDATION_EXPORT NSString* TGPrefFilePathInDirectory(NSString* preferencesDirectory);
FOUNDATION_EXPORT NSMutableDictionary* TGLoadPrefs(NSString* path);
FOUNDATION_EXPORT void TGSavePrefs(NSDictionary* prefs, NSString* path);
FOUNDATION_EXPORT void TGPostSettingsChanged(void);

//TabGuard was SafariBlocker (com.p2kdev.safariblocker), keep the user's lists and settings
FOUNDATION_EXPORT void TGMigrateSafariBlockerPrefs(NSString* preferencesDirectory);

//Lists are stored as ";" separated strings under allowedDomains, blockedDomains and blockedURLs
FOUNDATION_EXPORT BOOL TGIsListKey(NSString* key);
FOUNDATION_EXPORT NSMutableArray* TGListFromPrefs(NSDictionary* prefs, NSString* key);
FOUNDATION_EXPORT void TGStoreList(NSMutableDictionary* prefs, NSString* key, NSArray* list);

//A domain lives in one domain list only. Takes entry off the list opposite to key (if it's there) and returns
//that list's key, nil when nothing was removed. prefs is changed but not saved.
FOUNDATION_EXPORT NSString* TGOtherDomainListKey(NSString* key);
FOUNDATION_EXPORT NSString* TGRemoveFromOtherDomainList(NSMutableDictionary* prefs, NSString* key, NSString* entry);

//Strip the scheme (or the "//" left by resourceSpecifier) and a leading "www."
FOUNDATION_EXPORT NSString* TGStripSchemeAndWWW(NSString* url);
