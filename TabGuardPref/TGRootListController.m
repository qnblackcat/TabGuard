#import <Preferences/Preferences.h>
#import <Preferences/PSListController.h>
#include <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../TGPrefsShared.h"

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
	@property (nonatomic,copy) NSString *dataListKey;
	@property (nonatomic,strong) UIToolbar *keyboardToolbar;
	-(void)updateDataToPrefsFile;
	-(id)initWithListKey:(NSString *)key;
@end

NSString *prefFilePath;

static void presentAlert(UIViewController *controller, NSString *title, NSString *message)
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[controller presentViewController:alert animated:YES completion:nil];
}

static NSString *listTitle(NSString *key)
{
	return @{@"allowedDomains": @"Whitelisted Domains", @"blockedDomains": @"Blocked Domains", @"blockedURLs": @"Blocked URLs"}[key];
}

static NSString *entryPlaceholder(NSString *key)
{
	return [key isEqualToString:@"blockedURLs"] ? @"example.com/videos/" : @"example.com or *.example.com";
}

@implementation TGRootListController

- (id)init
{
	self = [super init];
	//Settings live in Safari's container, the tweak reads them from inside Safari's sandbox
	NSString *safariPreferences = [[[[objc_getClass("LSApplicationProxy") applicationProxyForIdentifier:@"com.apple.mobilesafari"] containerURL] path] stringByAppendingPathComponent:@"Library/Preferences"];
	prefFilePath = TGPrefFilePathInDirectory(safariPreferences);

	//Keep the user's lists and settings if Settings is opened before Safari
	TGMigrateSafariBlockerPrefs(safariPreferences);
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
	[self pushController:[[TGListController alloc] initWithListKey:@"allowedDomains"] animate:YES];
}

- (void)launchBlockedDomainOptions {
	[self pushController:[[TGListController alloc] initWithListKey:@"blockedDomains"] animate:YES];
}

- (void)launchBlockedURLOptions {
	[self pushController:[[TGListController alloc] initWithListKey:@"blockedURLs"] animate:YES];
}

-(id)readPreferenceValue:(PSSpecifier*)specifier {
	return TGLoadPrefs(prefFilePath)[[specifier propertyForKey:@"key"]] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {
	NSMutableDictionary *prefs = TGLoadPrefs(prefFilePath);
	[prefs setValue:value forKey:[specifier propertyForKey:@"key"]];
	TGSavePrefs(prefs, prefFilePath);

	CFStringRef toPost = (__bridge CFStringRef)specifier.properties[@"PostNotification"];
	if(toPost) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), toPost, NULL, NULL, YES);
}

//Writes every setting (switches, banner duration, all three lists) and tells Safari to reload them
- (void)replaceAllPreferences:(NSDictionary *)preferences
{
	TGSavePrefs(preferences, prefFilePath);
	TGPostSettingsChanged();
	[self reloadSpecifiers];
}

//A backup is a plist wrapping every stored preference, plus a marker so we don't import random plists
- (void)exportSettingsTapped:(PSSpecifier *)specifier
{
	NSDictionary *backup = @{
		@"TabGuardBackup": @1,
		@"preferences": TGLoadPrefs(prefFilePath)
	};

	NSError *error = nil;
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:backup format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
	NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"TabGuardBackup.plist"]];
	if (data == nil || ![data writeToURL:url options:NSDataWritingAtomic error:&error])
	{
		presentAlert(self, @"Export Failed", error.localizedDescription);
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

	//The picker may still be dismissing, so present once it's gone
	dispatch_async(dispatch_get_main_queue(), ^{
		if (backup[@"TabGuardBackup"] == nil || ![values isKindOfClass:[NSDictionary class]])
		{
			presentAlert(self, @"Import Failed", @"This file isn't a TabGuard backup.");
			return;
		}

		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Settings" message:@"All of your current TabGuard settings will be replaced by this backup. Are you sure?" preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		[alert addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
			[self replaceAllPreferences:values];
		}]];
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

- (id)initWithListKey:(NSString *)key
{
	self = [super init];
	if (self) {
		self.dataList = [[NSMutableArray alloc] init];
		self.dataListKey = key;
		self.title = listTitle(key);
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
	if (![self isDomainList])
		return TGStripSchemeAndWWW(entry);

	BOOL wildcard = [entry hasPrefix:@"*."];
	if (wildcard)
		entry = [entry substringFromIndex:2];

	NSURL *url = [NSURL URLWithString:([entry containsString:@"://"] ? entry : [@"https://" stringByAppendingString:entry])];
	entry = TGStripSchemeAndWWW(url.host.lowercaseString ?: entry.lowercaseString);

	return (wildcard && entry.length) ? [@"*." stringByAppendingString:entry] : entry;
}

- (void)addEntryTapped
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Entry" message:nil preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = entryPlaceholder(self.dataListKey);
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

//Why entry can't be in the list, nil when it can. The entry at ignoredIndex is the one being edited.
- (NSString *)problemWithEntry:(NSString *)entry ignoringIndex:(NSInteger)ignoredIndex
{
	if (entry.length == 0)
		return @"The entry is empty.";
	if ([entry containsString:@";"])
		return @"Entries can't contain \";\".";

	NSUInteger existing = [self.dataList indexOfObject:entry];
	if (existing != NSNotFound && (NSInteger)existing != ignoredIndex)
		return [NSString stringWithFormat:@"%@ is already in the list.", entry];
	return nil;
}

//A domain lives in one list only, adding it here takes it off the other domain list
- (void)moveEntryFromOtherList:(NSString *)entry
{
	NSMutableDictionary *prefs = TGLoadPrefs(prefFilePath);
	NSString *movedFromKey = TGRemoveFromOtherDomainList(prefs, self.dataListKey, entry);
	if (!movedFromKey)
		return;

	TGSavePrefs(prefs, prefFilePath);
	presentAlert(self, nil, [NSString stringWithFormat:@"Moved %@ from %@.", entry, listTitle(movedFromKey)]);
}

- (void)addEntry:(NSString *)input
{
	NSString *entry = [self cleanedEntry:input];

	NSString *problem = [self problemWithEntry:entry ignoringIndex:-1];
	if (problem)
	{
		presentAlert(self, @"Couldn't Add Entry", problem);
		return;
	}

	[self moveEntryFromOtherList:entry];
	[self.dataList addObject:entry];
	[self saveAndReload];
}

- (void)saveAndReload
{
	[self updateDataToPrefsFile];
	[self reloadSpecifiers];
	TGPostSettingsChanged();
}

//Rows are keyed "#1", "#2"... and follow the order of dataList
- (NSInteger)entryIndexForSpecifier:(PSSpecifier *)specifier
{
	return [[[specifier propertyForKey:@"key"] substringFromIndex:1] integerValue] - 1;
}

- (NSArray *)specifiers {
	if (!_specifiers) {

		_specifiers = [[NSMutableArray alloc] init];

		self.dataList = TGListFromPrefs(TGLoadPrefs(prefFilePath), self.dataListKey);

		for (NSUInteger i = 0; i < self.dataList.count; i++)
		{
			NSString *label = [NSString stringWithFormat:@"#%lu", (unsigned long)i + 1];
			PSTextFieldSpecifier  *newData = [PSTextFieldSpecifier preferenceSpecifierNamed:label
																									target:self
																									set:@selector(setPreferenceValue:specifier:)
																									get:@selector(readPreferenceValue:)
																									detail:Nil
																									cell:PSEditTextCell
																									edit:Nil];
			[newData setProperty:label forKey:@"key"];
			[newData setProperty:@YES forKey:@"enabled"];
			[newData setPlaceholder:entryPlaceholder(self.dataListKey)];
			[_specifiers addObject:newData];
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
		if (!self.keyboardToolbar)
		{
			self.keyboardToolbar = [[UIToolbar alloc] init];
			[self.keyboardToolbar sizeToFit];
			self.keyboardToolbar.items = @[
				[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
				[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneClicked:)]
			];
		}
		editableCell.textField.inputAccessoryView = self.keyboardToolbar;
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
	[self saveAndReload];
}

- (id)readPreferenceValue:(PSSpecifier*)specifier {
	NSInteger index = [self entryIndexForSpecifier:specifier];
	return index < (NSInteger)self.dataList.count ? self.dataList[index] : nil;
}

-(void)updateDataToPrefsFile
{
	NSMutableDictionary *prefs = TGLoadPrefs(prefFilePath);
	TGStoreList(prefs, self.dataListKey, self.dataList);
	TGSavePrefs(prefs, prefFilePath);
}

//An entry was edited in its text field, it gets the same cleaning and checks as a new entry
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {
	NSInteger index = [self entryIndexForSpecifier:specifier];
	if (index >= (NSInteger)self.dataList.count)
		return;

	NSString *input = [value isKindOfClass:[NSString class]] ? value : @"";
	NSString *entry = [self cleanedEntry:input];
	BOOL changed = ![entry isEqualToString:self.dataList[index]];

	NSString *problem = changed ? [self problemWithEntry:entry ignoringIndex:index] : nil;
	if (problem)
		presentAlert(self, @"Couldn't Change Entry", problem);
	else if (changed)
	{
		[self moveEntryFromOtherList:entry];
		self.dataList[index] = entry;
		[self updateDataToPrefsFile];
		TGPostSettingsChanged();
	}

	//Show what was actually saved: the cleaned entry, or the old one when the new text was refused
	if (problem || ![entry isEqualToString:input])
		dispatch_async(dispatch_get_main_queue(), ^{
			[self reloadSpecifiers];
		});
}

@end
