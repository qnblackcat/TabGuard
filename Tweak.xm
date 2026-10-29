#import "TGCommon.h"
#import "TGPrefs.h"
#import "TGPrefsShared.h"
#import "TGDelegateHook.h"

%hook WKWebView

- (void)setUIDelegate:(id<WKUIDelegate>)UIDelegate
{
  if (UIDelegate)
    hookUIDelegateClass(object_getClass(UIDelegate));

  %orig;
}

%end

%ctor
{
  TGLog(@"loaded");

  migrateSafariBlockerPrefs();
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)updatePrefs, TGSettingsChangedNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
  updatePrefs();

  %init;
}
