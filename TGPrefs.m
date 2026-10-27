#import "TGPrefs.h"

NSMutableArray* blockedURLs;
NSMutableArray* blockedDomains;
NSMutableArray* allowedDomains;
bool tweakEnabled = YES;
bool showBlockedBanner = YES;
NSTimeInterval bannerDuration = 6;

static NSMutableArray* listForKey(NSString* key)
{
  if ([key isEqualToString:@"allowedDomains"])
    return allowedDomains;
  if ([key isEqualToString:@"blockedDomains"])
    return blockedDomains;
  if ([key isEqualToString:@"blockedURLs"])
    return blockedURLs;
  return nil;
}

//key is one of allowedDomains, blockedDomains, blockedURLs. A domain lives in one list only, adding it to the
//whitelist takes it off the blocked domains and the other way around.
void editTabGuardList(NSString* key, NSString* entry, BOOL add)
{
  NSMutableArray* list = listForKey(key);
  if (!list || !entry || add == [list containsObject:entry])
    return;

  if (add)
    [list addObject:entry];
  else
    [list removeObject:entry];

  NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
  [defaults addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:prefFilePath]];
  [defaults setObject:[list componentsJoinedByString:@";"] forKey:key];

  NSString* otherKey = [key isEqualToString:@"allowedDomains"] ? @"blockedDomains" : ([key isEqualToString:@"blockedDomains"] ? @"allowedDomains" : nil);
  NSMutableArray* otherList = listForKey(otherKey);
  if (add && [otherList containsObject:entry])
  {
    [otherList removeObject:entry];
    [defaults setObject:[otherList componentsJoinedByString:@";"] forKey:otherKey];
  }

  [defaults writeToFile:prefFilePath atomically:YES];
}

//Pref lists are stored as ";" separated strings, ignore anything that isn't a string
static NSMutableArray* listPref(NSDictionary* prefs, NSString* key)
{
  id value = prefs[key];
  NSMutableArray* list = [([value isKindOfClass:[NSString class]] ? [value componentsSeparatedByString:@";"] : @[]) mutableCopy];
  [list removeObject:@""];
  return list;
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

  NSMutableArray* domains = listPref(prefs, @"allowedDomains");
  for (NSString* domain in defaultAllowedDomains())
  {
    if (![domains containsObject:domain])
      [domains addObject:domain];
  }

  [prefs setObject:[domains componentsJoinedByString:@";"] forKey:@"allowedDomains"];
  [prefs setObject:@YES forKey:@"addedDefaultAllowedDomains"];
  [prefs writeToFile:prefFilePath atomically:YES];
}

void updatePrefs(void)
{
  NSMutableDictionary* prefs = [[NSMutableDictionary alloc] initWithContentsOfFile:prefFilePath] ?: [NSMutableDictionary dictionary];
  addDefaultAllowedDomainsOnce(prefs);

  allowedDomains = listPref(prefs, @"allowedDomains");
  blockedDomains = listPref(prefs, @"blockedDomains");
  blockedURLs = listPref(prefs, @"blockedURLs");

  tweakEnabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
  showBlockedBanner = prefs[@"showBlockedBanner"] ? [prefs[@"showBlockedBanner"] boolValue] : YES;
  id duration = prefs[@"bannerDuration"];
  bannerDuration = [duration respondsToSelector:@selector(doubleValue)] && [duration doubleValue] > 0 ? MIN(MAX([duration doubleValue], 1), 60) : 6;
}

//TabGuard was SafariBlocker (com.p2kdev.safariblocker), keep the user's lists and settings
void migrateSafariBlockerPrefs(void)
{
  NSString* oldPath = [NSString stringWithFormat:@"%@/Library/Preferences/com.p2kdev.safariblocker.plist", NSHomeDirectory()];
  NSFileManager* fileManager = [NSFileManager defaultManager];
  if (![fileManager fileExistsAtPath:prefFilePath] && [fileManager fileExistsAtPath:oldPath])
    [fileManager copyItemAtPath:oldPath toPath:prefFilePath error:nil];
}
