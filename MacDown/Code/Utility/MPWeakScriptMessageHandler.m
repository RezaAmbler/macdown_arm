//
//  MPWeakScriptMessageHandler.m
//  MacDown
//

#import "MPWeakScriptMessageHandler.h"

@interface MPWeakScriptMessageHandler ()
@property (weak) id<WKScriptMessageHandler> target;
@end


@implementation MPWeakScriptMessageHandler

- (instancetype)initWithTarget:(id<WKScriptMessageHandler>)target
{
    self = [super init];
    if (self)
        _target = target;
    return self;
}

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    [self.target userContentController:controller
               didReceiveScriptMessage:message];
}

@end
