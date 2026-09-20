//
//  MPPreviewSchemeHandler.h
//  MacDown
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

/// Scheme used for the preview's base URL and its local subresources.
extern NSString * const kMPPreviewURLScheme;

/**
 * Serves local files to the preview.
 *
 * WKWebView will not load `file:` subresources for a page put up with
 * -loadHTMLString:baseURL:, so an image written as `![](picture.png)` next to
 * the document silently fails to appear -- something the legacy WebView did
 * without complaint.
 *
 * The preview is therefore loaded with a base URL in a private scheme that
 * mirrors the document's own path. Relative references resolve against it as
 * they always did, and land here to be read off disk.
 */
@interface MPPreviewSchemeHandler : NSObject <WKURLSchemeHandler>

/// Map a file URL to the preview scheme. Returns non-file URLs unchanged.
+ (NSURL *)previewURLForFileURL:(NSURL *)fileURL;

/// Map a preview-scheme URL back to a file URL. Returns others unchanged.
+ (NSURL *)fileURLForPreviewURL:(NSURL *)previewURL;

@end
