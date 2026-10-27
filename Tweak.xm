#import "TGCommon.h"
#import "TGPrefs.h"
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
  SBLog(@"loaded");

  migrateSafariBlockerPrefs();
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)updatePrefs, CFSTR("com.qn.tabguard.settingschanged"), NULL, CFNotificationSuspensionBehaviorCoalesce);
  updatePrefs();

  %init;
}
