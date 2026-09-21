//
//  MPPreviewWebView.m
//  MacDown
//

#import "MPPreviewWebView.h"

@implementation MPPreviewWebView

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender
{
    return NSDragOperationNone;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender
{
    return NO;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    return NO;
}

@end
