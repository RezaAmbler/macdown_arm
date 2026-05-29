//
//  MPGlobals.h
//  MacDown
//
//  Created by Tzu-ping Chung on 02/12.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "version.h"

// These should match the main bundle's values.
static NSString * const kMPApplicationName = @"MacDown";

#ifdef DEBUG
static NSString * const kMPApplicationBundleIdentifier = @"com.uranusjr.macdown-debug";
#else
static NSString * const kMPApplicationBundleIdentifier = @"com.uranusjr.macdown";
#endif

static NSString * const kMPApplicationSuiteName = @"com.uranusjr.macdown";

static NSString * const MPCommandInstallationPath = @"/usr/local/bin/macdown";
static NSString * const kMPCommandName = @"macdown";

static NSString * const kMPHelpKey = @"help";
static NSString * const kMPVersionKey = @"version";

static NSString * const kMPFilesToOpenKey = @"filesToOpenOnNextLaunch";
static NSString * const kMPPipedContentFileToOpen = @"pipedContentFileToOpenOnNextLaunch";

// Editor/preview appearance modes selectable from View ▸ Appearance.
// Light is the historical default, so it maps to zero (no defaults migration).
typedef NS_ENUM(NSInteger, MPViewMode) {
    MPViewModeLight = 0,
    MPViewModeDark  = 1,
    MPViewModeSepia = 2,
};
