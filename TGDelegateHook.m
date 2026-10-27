#import "TGDelegateHook.h"
#import "TGPopupRequest.h"
#import "TGPopupBanner.h"
#import "TGPrefs.h"

//Reads a private property only when it exists, nil instead of an exception if Apple renames it
static id valueForKeyIfResponds(id object, NSString* key)
{
  if (!object || ![object respondsToSelector:NSSelectorFromString(key)])
    return nil;

  @try
  {
    return [object valueForKey:key];
  }
  @catch(NSException* ex)
  {
    SBLog(@"valueForKey:%@ failed: %@", key, ex.reason);
    return nil;
  }
}

static UIViewController* rootViewControllerForWebView(WKWebView* webView)
{
  UIWindow* window = webView.window;
  if (!window)
  {
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes)
    {
      if (![scene isKindOfClass:[UIWindowScene class]])
        continue;

      for (UIWindow* sceneWindow in ((UIWindowScene*)scene).windows)
      {
        if (sceneWindow.isKeyWindow)
          window = sceneWindow;
      }
    }
  }
  return window.rootViewController;
}

//Returns YES when the pop-up may be created. Otherwise it was refused and the banner is already shown if needed.
static BOOL shouldCreatePopup(id uiDelegate, WKWebView* webView, WKNavigationAction* navigationAction)
{
  if (!tweakEnabled)
    return YES;

  SBPopupRequest* request = popupRequestFor(webView, navigationAction);
  SBPopupDecision decision = decisionForPopup(request);

  SBLog(@"pop-up page=%@ opener=%@ target=%@ decision=%ld", request.pageDomain, request.openerDomain, request.targetURL, (long)decision);

  if (decision == SBPopupAllow)
    return YES;

  UIViewController* rootVC = rootViewControllerForWebView(webView);
  id browserController = valueForKeyIfResponds(uiDelegate, @"browserController") ?: valueForKeyIfResponds(rootVC, @"browserController");

  BOOL ask = decision == SBPopupAsk;
  if (!rootVC.view)
  {
    SBLog(@"no view to show the banner in");
    return ask;
  }

  if (ask || showBlockedBanner)
    [SBPopupBanner showForRequest:request inViewController:rootVC browserController:browserController];
  return NO;
}

//Every pop-up from web content (window.open, target="_blank", form targets) asks the web view's UI delegate
//for a new web view, before anything is created or loaded. Refusing it there means no tab, no request,
//no History entry, and window.open() returns null to the page. Tabs the user opens from Safari's own UI
//(long press, "Open in New Tab", other tweaks calling loadURLInNewTab) never come through here.
//
//Which class is the UI delegate differs between Safari versions, and WebKit prefers the private async
//variant when the delegate has it, so both are hooked on whatever class Safari actually sets.
typedef WKWebView* (*SBCreateWebViewIMP)(id, SEL, WKWebView*, WKWebViewConfiguration*, WKNavigationAction*, WKWindowFeatures*);
typedef void (*SBCreateWebViewAsyncIMP)(id, SEL, WKWebView*, WKWebViewConfiguration*, WKNavigationAction*, WKWindowFeatures*, void (^)(WKWebView*));

static NSMutableSet<NSString*>* hookedMethods;

//The class that actually implements sel, hooking a subclass that only inherits it would hook it twice
static Class definingClassForSelector(Class cls, SEL sel)
{
  Method method = class_getInstanceMethod(cls, sel);
  if (!method)
    return nil;

  Class owner = cls;
  while (class_getSuperclass(owner) && class_getInstanceMethod(class_getSuperclass(owner), sel) == method)
    owner = class_getSuperclass(owner);
  return owner;
}

static Method methodToHook(Class cls, SEL sel)
{
  Class owner = definingClassForSelector(cls, sel);
  if (!owner)
    return NULL;

  NSString* key = [NSString stringWithFormat:@"%s %@", class_getName(owner), NSStringFromSelector(sel)];
  if (!hookedMethods)
    hookedMethods = [NSMutableSet new];

  if ([hookedMethods containsObject:key])
    return NULL;

  [hookedMethods addObject:key];
  SBLog(@"hooking -[%s %@]", class_getName(owner), NSStringFromSelector(sel));
  return class_getInstanceMethod(owner, sel);
}

void hookUIDelegateClass(Class cls)
{
  SEL syncSel = @selector(webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:);
  Method syncMethod = methodToHook(cls, syncSel);
  if (syncMethod)
  {
    SBCreateWebViewIMP orig = (SBCreateWebViewIMP)method_getImplementation(syncMethod);
    method_setImplementation(syncMethod, imp_implementationWithBlock(^WKWebView*(id delegate, WKWebView* webView, WKWebViewConfiguration* configuration, WKNavigationAction* navigationAction, WKWindowFeatures* windowFeatures) {
      if (!shouldCreatePopup(delegate, webView, navigationAction))
        return nil;

      return orig(delegate, syncSel, webView, configuration, navigationAction, windowFeatures);
    }));
  }

  SEL asyncSel = NSSelectorFromString(@"_webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:completionHandler:");
  Method asyncMethod = methodToHook(cls, asyncSel);
  if (asyncMethod)
  {
    SBCreateWebViewAsyncIMP orig = (SBCreateWebViewAsyncIMP)method_getImplementation(asyncMethod);
    method_setImplementation(asyncMethod, imp_implementationWithBlock(^(id delegate, WKWebView* webView, WKWebViewConfiguration* configuration, WKNavigationAction* navigationAction, WKWindowFeatures* windowFeatures, void (^completionHandler)(WKWebView*)) {
      if (!shouldCreatePopup(delegate, webView, navigationAction))
      {
        completionHandler(nil);
        return;
      }

      orig(delegate, asyncSel, webView, configuration, navigationAction, windowFeatures, completionHandler);
    }));
  }
}
