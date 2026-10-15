#import <Preferences/Preferences.h>
#import <Preferences/PSListController.h>
#include <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface PSTextFieldSpecifier : PSSpecifier
	-(void)setPlaceholder:(NSString *)placeholder;
@end

@interface PSEditableTableCell (Private)
	@property (nonatomic, readonly) UITextField *textField;
@end

@interface LSApplicationProxy
	+(id)applicationProxyForIdentifier:(NSString *)bundleId;
	-(NSURL *)containerURL;
@end

@interface TGRootListController : PSListController <UIDocumentPickerDelegate>
@end

@interface TGListController : PSListController
	@property (nonatomic,retain) NSMutableArray *dataList;
	@property (nonatomic,assign) NSString *dataListKey;
	-(void)updateDataToPrefsFile;
	-(id)initForType:(int)type;
@end

NSString *prefFilePath;

@implementation TGRootListController

- (id)init
{
	self = [super init];
	//Settings live in Safari's container, the tweak reads them from inside Safari's sandbox
	NSString *safariPreferences = [[[[objc_getClass("LSApplicationProxy") applicationProxyForIdentifier:@"com.apple.mobilesafari"] containerURL] path] stringByAppendingPathComponent:@"Library/Preferences"];
	prefFilePath = [safariPreferences stringByAppendingPathComponent:@"com.qn.tabguard.plist"];

	//TabGuard was SafariBlocker, keep the user's lists and settings if Settings is opened before Safari
	NSString *oldPath = [safariPreferences stringByAppendingPathComponent:@"com.p2kdev.safariblocker.plist"];
	if (![[NSFileManager defaultManager] fileExistsAtPath:prefFilePath] && [[NSFileManager defaultManager] fileExistsAtPath:oldPath])
		[[NSFileManager defaultManager] copyItemAtPath:oldPath toPath:prefFilePath error:nil];
	return self;
}

- (id)specifiers
{
	if(_specifiers == nil)
	{
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

- (void)launchAllowedDomainOptions {
	[self pushController:[[TGListController alloc] initForType:1] animate:YES];
}

- (void)launchBlockedDomainOptions {
	[self pushController:[[TGListController alloc] initForType:2] animate:YES];
}

- (void)launchBlockedURLOptions {
	[self pushController:[[TGListController alloc] initForType:3] animate:YES];
}

-(id)readPreferenceValue:(PSSpecifier*)specifier {
    NSDictionary *tweakSettings = [NSDictionary dictionaryWithContentsOfFile:prefFilePath];

		NSString *key = [specifier propertyForKey:@"key"];
		id defaultValue = [specifier propertyForKey:@"default"];
		id plistValue = [tweakSettings objectForKey:key];

		if (!plistValue) plistValue = defaultValue;

    return plistValue;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {

		NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
		[defaults addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:prefFilePath]];

		NSString *newKey = [specifier propertyForKey:@"key"];
		id specifierValue = value;
		[defaults setObject:specifierValue forKey:newKey];
		[defaults writeToFile:prefFilePath atomically:YES];

		CFStringRef toPost = (__bridge CFStringRef)specifier.properties[@"PostNotification"];
		if(toPost) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), toPost, NULL, NULL, YES);
}

- (void)showMessage:(NSString *)message title:(NSString *)title
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

//Writes every setting (switches, banner duration, all three lists) and tells Safari to reload them
- (void)replaceAllPreferences:(NSDictionary *)preferences
{
	[preferences writeToFile:prefFilePath atomically:YES];
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.qn.tabguard.settingschanged"), NULL, NULL, YES);
	[self reloadSpecifiers];
}

//A backup is a plist wrapping every stored preference, plus a marker so we don't import random plists
- (void)exportSettingsTapped:(PSSpecifier *)specifier
{
	NSDictionary *backup = @{
		@"TabGuardBackup": @1,
		@"preferences": [NSDictionary dictionaryWithContentsOfFile:prefFilePath] ?: @{}
	};

	NSError *error = nil;
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:backup format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
	NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"TabGuardBackup.plist"]];
	if (data == nil || ![data writeToURL:url options:NSDataWritingAtomic error:&error])
	{
		[self showMessage:error.localizedDescription title:@"Export Failed"];
		return;
	}

	UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
	share.popoverPresentationController.sourceView = self.view;
	share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
	[self presentViewController:share animated:YES completion:nil];
}

- (void)importSettingsTapped:(PSSpecifier *)specifier
{
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePropertyList] asCopy:YES];
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	NSData *data = urls.firstObject ? [NSData dataWithContentsOfURL:urls.firstObject] : nil;
	id backup = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
	NSDictionary *values = [backup isKindOfClass:[NSDictionary class]] ? backup[@"preferences"] : nil;

	UIAlertController *alert;
	if (backup[@"TabGuardBackup"] == nil || ![values isKindOfClass:[NSDictionary class]])
	{
		alert = [UIAlertController alertControllerWithTitle:@"Import Failed" message:@"This file isn't a TabGuard backup." preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	}
	else
	{
		alert = [UIAlertController alertControllerWithTitle:@"Import Settings" message:@"All of your current TabGuard settings will be replaced by this backup. Are you sure?" preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		[alert addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
			[self replaceAllPreferences:values];
		}]];
	}

	//The picker may still be dismissing, so present once it's gone
	dispatch_async(dispatch_get_main_queue(), ^{
		[self presentViewController:alert animated:YES completion:nil];
	});
}

- (void)resetSettingsTapped:(PSSpecifier *)specifier
{
	//Safari adds the default whitelist again the next time it loads the settings
	[self replaceAllPreferences:@{}];
}

- (void)visitGitHub {
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/qnblackcat/TabGuard"] options:@{} completionHandler:nil];
}

@end

@implementation TGListController

- (id)initForType:(int)type
{
	self = [super init];
	if (self) {

		self.dataList = [[NSMutableArray alloc] init];
		if (type == 1)
			self.dataListKey = @"allowedDomains";
		else if (type == 2)
			self.dataListKey = @"blockedDomains";
		else if (type == 3)
			self.dataListKey = @"blockedURLs";

		NSDictionary *titles = @{@"allowedDomains": @"Whitelisted Domains", @"blockedDomains": @"Blocked Domains", @"blockedURLs": @"Blocked URLs"};
		self.title = titles[self.dataListKey];
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addEntryTapped)];
}

- (BOOL)isDomainList
{
	return ![self.dataListKey isEqualToString:@"blockedURLs"];
}

//Same shape as entries saved from the banner: no scheme, no "www.", domains lowercased and without a path
- (NSString *)cleanedEntry:(NSString *)input
{
	NSString *entry = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	if ([self isDomainList])
	{
		BOOL wildcard = [entry hasPrefix:@"*."];
		if (wildcard)
			entry = [entry substringFromIndex:2];

		NSURL *url = [NSURL URLWithString:([entry containsString:@"://"] ? entry : [@"https://" stringByAppendingString:entry])];
		entry = url.host.lowercaseString ?: entry.lowercaseString;
		if ([entry hasPrefix:@"www."])
			entry = [entry substringFromIndex:4];

		return (wildcard && entry.length) ? [@"*." stringByAppendingString:entry] : entry;
	}

	for (NSString *prefix in @[@"https://", @"http://"])
	{
		if ([entry.lowercaseString hasPrefix:prefix])
		{
			entry = [entry substringFromIndex:prefix.length];
			break;
		}
	}
	if ([entry.lowercaseString hasPrefix:@"www."])
		entry = [entry substringFromIndex:4];
	return entry;
}

- (void)addEntryTapped
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Entry" message:nil preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = [self isDomainList] ? @"example.com or *.example.com" : @"example.com/videos/";
		textField.keyboardType = UIKeyboardTypeURL;
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
	}];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[self addEntry:alert.textFields.firstObject.text];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)addEntry:(NSString *)input
{
	NSString *entry = [self cleanedEntry:input];

	NSString *problem = nil;
	if (entry.length == 0)
		problem = @"The entry is empty.";
	else if ([entry containsString:@";"])
		problem = @"Entries can't contain \";\".";
	else if ([self.dataList containsObject:entry])
		problem = [NSString stringWithFormat:@"%@ is already in the list.", entry];

	if (problem)
	{
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Add Entry" message:problem preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	//A domain lives in one list only, adding it here takes it off the other domain list
	NSString *movedFrom = [self removeFromOtherDomainList:entry];

	[self.dataList addObject:entry];
	[self updateDataToPrefsFile];
	[self reloadSpecifiers];
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.qn.tabguard.settingschanged"), NULL, NULL, YES);

	if (movedFrom)
	{
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:[NSString stringWithFormat:@"Moved %@ from %@.", entry, movedFrom] preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
	}
}

//Returns the other list's title when the entry was removed from it
- (NSString *)removeFromOtherDomainList:(NSString *)entry
{
	NSString *otherKey = [self.dataListKey isEqualToString:@"allowedDomains"] ? @"blockedDomains" : ([self.dataListKey isEqualToString:@"blockedDomains"] ? @"allowedDomains" : nil);
	if (!otherKey)
		return nil;

	NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
	[prefs addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:prefFilePath]];
	id value = prefs[otherKey];
	NSMutableArray *otherList = [([value isKindOfClass:[NSString class]] ? [value componentsSeparatedByString:@";"] : @[]) mutableCopy];
	if (![otherList containsObject:entry])
		return nil;

	[otherList removeObject:entry];
	[otherList removeObject:@""];
	prefs[otherKey] = [otherList componentsJoinedByString:@";"];
	[prefs writeToFile:prefFilePath atomically:YES];

	return [otherKey isEqualToString:@"allowedDomains"] ? @"Whitelisted Domains" : @"Blocked Domains";
}

- (NSArray *)specifiers {
	if (!_specifiers) {

		_specifiers = [[NSMutableArray alloc] init];

		NSMutableDictionary *tweakSettings = [[NSMutableDictionary alloc] initWithContentsOfFile:prefFilePath];
		id plistValue = [tweakSettings objectForKey:self.dataListKey];

		if (plistValue)
		{
			int index = 1;
			self.dataList = [[plistValue componentsSeparatedByString:@";"] mutableCopy];
			//Blank entries would shift the row numbers away from the list indexes used for editing and deleting
			[self.dataList removeObject:@""];

			for (NSString *currData in self.dataList)
			{
				if ([currData length] == 0)
					continue;

				NSString *newDataLabel = [NSString stringWithFormat:@"#%d",index];
				PSTextFieldSpecifier  *newData = [PSTextFieldSpecifier preferenceSpecifierNamed:newDataLabel
																										target:self
																										set:@selector(setPreferenceValue:specifier:)
																										get:@selector(readPreferenceValue:)
																										detail:Nil
																										cell:PSEditTextCell
																										edit:Nil];
				[newData setProperty:newDataLabel forKey:@"key"];
				[newData setProperty:@"com.qn.tabguard.settingschanged" forKey:@"PostNotification"];
				[newData setProperty:@YES forKey:@"enabled"];
				[newData setPlaceholder:[self isDomainList] ? @"example.com or *.example.com" : @"example.com/videos/"];
				[_specifiers addObject:newData];

				index++;
			}
		}
	}

	return _specifiers;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

	//Give every entry's text field a Done button to close the keyboard
	if ([cell isKindOfClass:objc_getClass("PSEditableTableCell")])
	{
		PSEditableTableCell *editableCell = (PSEditableTableCell *)cell;
		if (editableCell.textField)
		{
			UIToolbar *keyboardDoneButtonView = [[UIToolbar alloc] init];
			[keyboardDoneButtonView sizeToFit];
			UIBarButtonItem *flexBarButton = [[UIBarButtonItem alloc]
			    initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
			    target:self action:nil];

			UIBarButtonItem *doneBarButton = [[UIBarButtonItem alloc]
			    initWithBarButtonSystemItem:UIBarButtonSystemItemDone
			    target:self action:@selector(doneClicked:)];

			keyboardDoneButtonView.items = [NSArray arrayWithObjects:flexBarButton,doneBarButton,nil];
	    ((UITextField *)editableCell.textField).inputAccessoryView = keyboardDoneButtonView;
		}
	}

	return cell;
}

- (IBAction)doneClicked:(id)sender
{
    [self.view endEditing:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
	//Every row is an entry and can be swiped to delete
	return indexPath.row < (NSInteger)self.dataList.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
	[self.dataList removeObjectAtIndex:indexPath.row];
	[self updateDataToPrefsFile];
	[self reloadSpecifiers];
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.qn.tabguard.settingschanged"), NULL, NULL, YES);
}

- (id)readPreferenceValue:(PSSpecifier*)specifier {

	id plistValue = nil;
	NSString *key = [specifier propertyForKey:@"key"];
	if ([key hasPrefix:@"#"])
	{
		key = [key stringByReplacingOccurrencesOfString:@"#"	withString:@""];
		int objectIndex = [key integerValue]-1;
		if ([self.dataList count] > objectIndex)
			plistValue = [self.dataList objectAtIndex:[key integerValue]-1];
	}

	return plistValue;
}

-(void)updateDataToPrefsFile
{
	NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
	[defaults addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:prefFilePath]];
	[defaults setObject:[self.dataList componentsJoinedByString:@";"] forKey:self.dataListKey];
	[defaults writeToFile:prefFilePath atomically:YES];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {

		NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
		[defaults addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:prefFilePath]];

		NSString *newKey = [specifier propertyForKey:@"key"];
		id specifierValue = value;
		if ([newKey hasPrefix:@"#"])
		{
			newKey = [newKey stringByReplacingOccurrencesOfString:@"#"	withString:@""];

			self.dataList[[newKey integerValue]-1] = specifierValue;
			specifierValue = [self.dataList componentsJoinedByString:@";"];
			newKey = self.dataListKey;
		}

		[defaults setObject:specifierValue forKey:newKey];
		[defaults writeToFile:prefFilePath atomically:YES];

		CFStringRef toPost = (__bridge CFStringRef)specifier.properties[@"PostNotification"];
		if(toPost) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), toPost, NULL, NULL, YES);
}

@end
