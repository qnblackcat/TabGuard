#import "TGPopupRequest.h"
#import "TGPrefs.h"
#import "TGPrefsShared.h"

static NSString* normalizedHost(NSString* host)
{
  if (host.length == 0)
    return nil;

  return TGStripSchemeAndWWW(host.lowercaseString);
}

//How specific a matching entry is, the more specific side wins when a pop-up matches both the whitelist and
//a blocked list: blocked URL > exact domain > wildcard, longer wildcards before shorter ones
static const NSInteger TGSpecificityWildcard = 1000;
static const NSInteger TGSpecificityDomain = 2000;
static const NSInteger TGSpecificityURL = 3000;

//"example.com" only matches itself, "*.example.com" also covers every subdomain like "ads.example.com".
//Returns the most specific entry matching host, and its specificity (0 when nothing matched).
static NSString* bestEntryMatchingHost(NSString* host, NSArray* domains, NSInteger* specificity)
{
  NSString* best = nil;
  NSInteger bestScore = 0;

  for (NSString* entry in host ? domains : @[])
  {
    NSString* trimmed = [entry stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    BOOL wildcard = [trimmed hasPrefix:@"*."];
    NSString* domain = normalizedHost(wildcard ? [trimmed substringFromIndex:2] : trimmed);
    if (!domain)
      continue;

    NSInteger score = 0;
    if ([host isEqualToString:domain])
      score = wildcard ? TGSpecificityWildcard + domain.length : TGSpecificityDomain;
    else if (wildcard && [host hasSuffix:[@"." stringByAppendingString:domain]])
      score = TGSpecificityWildcard + domain.length;

    if (score > bestScore)
    {
      best = entry;
      bestScore = score;
    }
  }

  if (specificity)
    *specificity = bestScore;
  return best;
}

@implementation TGPopupRequest
@end

//"example.com/path" without scheme, www., query or fragment, so a saved entry still matches when tracking
//parameters change. Saved entries are matched as a prefix of the full address.
static NSString* addressWithoutQuery(NSURL* url)
{
  NSString* host = normalizedHost(url.host);
  if (!host)
    return nil;

  NSString* path = url.path.length > 1 ? url.path : @"";
  return [host stringByAppendingString:path];
}

TGPopupRequest* popupRequestFor(WKWebView* webView, WKNavigationAction* action)
{
  TGPopupRequest* request = [TGPopupRequest new];

  request.pageDomain = normalizedHost(webView.URL.host);
  request.pageURLWithoutJunk = TGStripSchemeAndWWW(webView.URL.resourceSpecifier);
  request.pageAddress = addressWithoutQuery(webView.URL);

  WKFrameInfo* sourceFrame = action.sourceFrame;
  NSString* openerHost = sourceFrame.securityOrigin.host;
  if (openerHost.length == 0)
    openerHost = sourceFrame.request.URL.host;
  request.openerDomain = normalizedHost(openerHost) ?: request.pageDomain;

  NSURL* target = action.request.URL;
  NSString* scheme = target.scheme.lowercaseString;
  if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])
  {
    request.targetURL = target;
    request.targetURLWithoutJunk = TGStripSchemeAndWWW(target.resourceSpecifier);
    request.targetAddress = addressWithoutQuery(target);
    request.targetDomain = normalizedHost(target.host);
  }

  return request;
}


TGPopupDecision decisionForPopup(TGPopupRequest* request)
{
  //Whitelist: pop-ups on these pages, or going to these domains (sign-in, payment)
  NSInteger pageAllowScore, targetAllowScore;
  bestEntryMatchingHost(request.pageDomain, allowedDomains, &pageAllowScore);
  bestEntryMatchingHost(request.targetDomain, allowedDomains, &targetAllowScore);
  NSInteger allowScore = MAX(pageAllowScore, targetAllowScore);

  //Blocked lists: the page, the frame that opened the pop-up, or where it goes
  NSInteger blockScore = 0;
  NSString* blockEntry = nil;
  NSString* blockListKey = nil;

  NSInteger score;
  NSString* entry;
  for (NSString* host in @[request.pageDomain ?: @"", request.openerDomain ?: @"", request.targetDomain ?: @""])
  {
    entry = bestEntryMatchingHost(host.length ? host : nil, blockedDomains, &score);
    if (score > blockScore)
    {
      blockScore = score;
      blockEntry = entry;
      blockListKey = @"blockedDomains";
    }
  }


  for (NSString* tempURL in blockedURLs)
  {
    NSString* blockedURL = TGStripSchemeAndWWW(tempURL);
    if (blockedURL.length && ([request.pageURLWithoutJunk hasPrefix:blockedURL] || [request.targetURLWithoutJunk hasPrefix:blockedURL]))
    {
      score = TGSpecificityURL + blockedURL.length;
      if (score > blockScore)
      {
        blockScore = score;
        blockEntry = tempURL;
        blockListKey = @"blockedURLs";
      }
    }
  }

  //Equally specific: blocking wins, blocked entries are deliberate while the whitelist has defaults
  if (blockScore > 0 && blockScore >= allowScore)
  {
    request.blockingEntry = blockEntry;
    request.blockingListKey = blockListKey;
    return TGPopupBlocked;
  }

  if (allowScore > 0)
    return TGPopupAllow;

  return TGPopupAsk;
}
