//
//  MPWeakScriptMessageHandler.h
//  MacDown
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

/**
 * Forwards script messages to a weakly-held target.
 *
 * WKUserContentController retains its message handlers, and the web view
 * retains the content controller, so registering the document directly would
 * keep it alive forever. Registering one of these instead breaks the cycle.
 */
@interface MPWeakScriptMessageHandler : NSObject <WKScriptMessageHandler>

- (instancetype)initWithTarget:(id<WKScriptMessageHandler>)target;

@property (weak, readonly) id<WKScriptMessageHandler> target;

@end
