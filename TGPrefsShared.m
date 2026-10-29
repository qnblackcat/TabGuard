#import "TGPrefsShared.h"

NSString* TGPrefFilePathInDirectory(NSString* preferencesDirectory)
{
  return [preferencesDirectory stringByAppendingPathComponent:@"com.qn.tabguard.plist"];
}

NSMutableDictionary* TGLoadPrefs(NSString* path)
{
  return [[NSMutableDictionary alloc] initWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
}

void TGSavePrefs(NSDictionary* prefs, NSString* path)
{
  [prefs writeToFile:path atomically:YES];
}

void TGPostSettingsChanged(void)
{
  CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), TGSettingsChangedNotification, NULL, NULL, YES);
}

void TGMigrateSafariBlockerPrefs(NSString* preferencesDirectory)
{
  NSString* path = TGPrefFilePathInDirectory(preferencesDirectory);
  NSString* oldPath = [preferencesDirectory stringByAppendingPathComponent:@"com.p2kdev.safariblocker.plist"];
  NSFileManager* fileManager = [NSFileManager defaultManager];
  if (![fileManager fileExistsAtPath:path] && [fileManager fileExistsAtPath:oldPath])
    [fileManager copyItemAtPath:oldPath toPath:path error:nil];
}

BOOL TGIsListKey(NSString* key)
{
  return [@[@"allowedDomains", @"blockedDomains", @"blockedURLs"] containsObject:key];
}

//Ignore anything that isn't a string
NSMutableArray* TGListFromPrefs(NSDictionary* prefs, NSString* key)
{
  id value = prefs[key];
  NSMutableArray* list = [([value isKindOfClass:[NSString class]] ? [value componentsSeparatedByString:@";"] : @[]) mutableCopy];
  [list removeObject:@""];
  return list;
}

void TGStoreList(NSMutableDictionary* prefs, NSString* key, NSArray* list)
{
  prefs[key] = [list componentsJoinedByString:@";"];
}

NSString* TGOtherDomainListKey(NSString* key)
{
  if ([key isEqualToString:@"allowedDomains"])
    return @"blockedDomains";
  if ([key isEqualToString:@"blockedDomains"])
    return @"allowedDomains";
  return nil;
}

NSString* TGRemoveFromOtherDomainList(NSMutableDictionary* prefs, NSString* key, NSString* entry)
{
  NSString* otherKey = TGOtherDomainListKey(key);
  NSMutableArray* otherList = otherKey ? TGListFromPrefs(prefs, otherKey) : nil;
  if (![otherList containsObject:entry])
    return nil;

  [otherList removeObject:entry];
  TGStoreList(prefs, otherKey, otherList);
  return otherKey;
}

static NSString* removePrefix(NSString* string, NSArray<NSString*>* prefixes)
{
  for (NSString* prefix in prefixes)
  {
    if ([string rangeOfString:prefix options:NSAnchoredSearch | NSCaseInsensitiveSearch].location != NSNotFound)
      return [string substringFromIndex:prefix.length];
  }
  return string;
}

NSString* TGStripSchemeAndWWW(NSString* url)
{
  return removePrefix(removePrefix(url, @[@"https://", @"http://", @"//"]), @[@"www."]);
}
