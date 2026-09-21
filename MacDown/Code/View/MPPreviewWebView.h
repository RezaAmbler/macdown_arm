//
//  MPPreviewWebView.h
//  MacDown
//

#import <WebKit/WebKit.h>

/**
 * The preview's web view.
 *
 * Exists only to refuse drags. The legacy WebView had a delegate method for
 * this (-webView:dragDestinationActionMaskForDraggingInfo:, wired through the
 * xib's UIDelegate outlet); WKWebView has no equivalent, and without this a
 * file dropped on the preview navigates away from the rendered document.
 */
@interface MPPreviewWebView : WKWebView

@end
