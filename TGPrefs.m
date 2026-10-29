#import "TGPrefs.h"
#import "TGPrefsShared.h"

NSMutableArray* blockedURLs;
NSMutableArray* blockedDomains;
NSMutableArray* allowedDomains;
bool tweakEnabled = YES;
bool showBlockedBanner = YES;
NSTimeInterval bannerDuration = 6;

//Store the preferences in Safari Home Directory to avoid sandbox issues
static NSString* prefsDirectory(void)
{
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
}

static NSString* prefFilePath(void)
{
  return TGPrefFilePathInDirectory(prefsDirectory());
}

//Sites with legitimate pop-ups (sign-in, payment, docs). Added to the user's whitelist once, so they
//show up in settings and stay deleted if the user removes them.
static NSArray* defaultAllowedDomains()
{
  return @[
    @"*.google.com",
    @"*.youtube.com",
    @"*.apple.com",
    @"*.icloud.com",
    @"*.microsoft.com",
    @"*.microsoftonline.com",
    @"*.live.com",
    @"*.office.com",
    @"*.github.com",
    @"*.wikipedia.org",
    @"*.facebook.com",
    @"*.paypal.com",
    @"*.stripe.com",
  ];
}

static void addDefaultAllowedDomainsOnce(NSMutableDictionary* prefs)
{
  if ([[prefs objectForKey:@"addedDefaultAllowedDomains"] boolValue])
    return;

  NSMutableArray* domains = TGListFromPrefs(prefs, @"allowedDomains");
  for (NSString* domain in defaultAllowedDomains())
  {
    if (![domains containsObject:domain])
      [domains addObject:domain];
  }

  TGStoreList(prefs, @"allowedDomains", domains);
  [prefs setObject:@YES forKey:@"addedDefaultAllowedDomains"];
  TGSavePrefs(prefs, prefFilePath());
}

static void applyPrefs(NSDictionary* prefs)
{
  allowedDomains = TGListFromPrefs(prefs, @"allowedDomains");
  blockedDomains = TGListFromPrefs(prefs, @"blockedDomains");
  blockedURLs = TGListFromPrefs(prefs, @"blockedURLs");

  tweakEnabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
  showBlockedBanner = prefs[@"showBlockedBanner"] ? [prefs[@"showBlockedBanner"] boolValue] : YES;
  id duration = prefs[@"bannerDuration"];
  bannerDuration = [duration respondsToSelector:@selector(doubleValue)] && [duration doubleValue] > 0 ? MIN(MAX([duration doubleValue], 1), 60) : 6;
}

void updatePrefs(void)
{
  NSMutableDictionary* prefs = TGLoadPrefs(prefFilePath());
  addDefaultAllowedDomainsOnce(prefs);
  applyPrefs(prefs);
}

//key is one of allowedDomains, blockedDomains, blockedURLs. A domain lives in one list only, adding it to the
//whitelist takes it off the blocked domains and the other way around.
void editTabGuardList(NSString* key, NSString* entry, BOOL add)
{
  if (!entry || !TGIsListKey(key))
    return;

  NSMutableDictionary* prefs = TGLoadPrefs(prefFilePath());
  NSMutableArray* list = TGListFromPrefs(prefs, key);
  if (add == [list containsObject:entry])
    return;

  if (add)
    [list addObject:entry];
  else
    [list removeObject:entry];
  TGStoreList(prefs, key, list);

  if (add)
    TGRemoveFromOtherDomainList(prefs, key, entry);

  TGSavePrefs(prefs, prefFilePath());
  applyPrefs(prefs);
}

void migrateSafariBlockerPrefs(void)
{
  TGMigrateSafariBlockerPrefs(prefsDirectory());
}
