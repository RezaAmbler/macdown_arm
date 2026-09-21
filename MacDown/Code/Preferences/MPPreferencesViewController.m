//
//  MPPreferencesViewController.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 7/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPPreferencesViewController.h"
#import "MPPreferences.h"


NSString * const MPDidRequestPreviewRenderNotification =
    @"MPDidRequestPreviewRenderNotificationName";
NSString * const MPDidRequestEditorSetupNotification =
    @"MPDidRequestEditorSetupNotificationName";

/// The size every preference pane is presented at.
///
/// Wide enough that the window's toolbar shows all five panes without
/// collapsing into a ">>" overflow menu, and tall enough for the tallest
/// pane (Editor, and Rendering once the diagram options got their own row).
static const CGFloat kMPPreferencesPaneWidth = 620.0;
static const CGFloat kMPPreferencesPaneHeight = 420.0;


@implementation MPPreferencesViewController

- (id)init
{
    return [self initWithNibName:NSStringFromClass(self.class)
                          bundle:nil];
}

/** Present every pane at one fixed size.
 *
 * MASPreferences sizes the window to whichever pane is selected, so switching
 * panes made the window jump around, and on the narrower panes the toolbar
 * did not fit and collapsed into a ">>" overflow menu.
 *
 * The panes are not simply resized to match, because they do not all use the
 * same layout system: some subviews still rely on autoresizing masks, and
 * growing the nib's root view stretched them. Instead the nib's view is left
 * at its natural size and parked in the top-left of a fixed-size container,
 * which is what the window then sizes itself to. Nothing inside a pane
 * moves; the panes that need less room simply leave empty space below and to
 * the right.
 */
- (void)loadView
{
    [super loadView];

    NSView *pane = self.view;
    if (!pane || pane.frame.size.width <= 0.0)
        return;

    NSSize paneSize = pane.frame.size;
    NSSize containerSize = NSMakeSize(MAX(kMPPreferencesPaneWidth, paneSize.width),
                                      MAX(kMPPreferencesPaneHeight, paneSize.height));

    // Already the right size; nothing to wrap.
    if (NSEqualSizes(paneSize, containerSize))
        return;

    NSView *container =
        [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0,
                                                 containerSize.width,
                                                 containerSize.height)];

    // Top-left, at its natural size, and staying there if the container is
    // ever resized.
    pane.translatesAutoresizingMaskIntoConstraints = YES;
    pane.frame = NSMakeRect(0.0, containerSize.height - paneSize.height,
                            paneSize.width, paneSize.height);
    pane.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;

    [container addSubview:pane];
    self.view = container;
}

- (MPPreferences *)preferences
{
    return [MPPreferences sharedInstance];
}

@end
