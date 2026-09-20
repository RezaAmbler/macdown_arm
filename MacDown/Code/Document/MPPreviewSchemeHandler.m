//
//  MPPreviewSchemeHandler.m
//  MacDown
//

#import "MPPreviewSchemeHandler.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString * const kMPPreviewURLScheme = @"macdown-preview";


@implementation MPPreviewSchemeHandler

#pragma mark - URL mapping

+ (NSURL *)previewURLForFileURL:(NSURL *)fileURL
{
    if (!fileURL.isFileURL)
        return fileURL;

    NSURLComponents *components =
        [NSURLComponents componentsWithURL:fileURL resolvingAgainstBaseURL:YES];
    components.scheme = kMPPreviewURLScheme;

    // A file URL has an empty host; the custom scheme needs one for the URL
    // to be treated as hierarchical and resolve relative references.
    components.host = @"localhost";
    return components.URL ?: fileURL;
}

+ (NSURL *)fileURLForPreviewURL:(NSURL *)previewURL
{
    if (![previewURL.scheme isEqualToString:kMPPreviewURLScheme])
        return previewURL;

    NSURLComponents *components =
        [NSURLComponents componentsWithURL:previewURL resolvingAgainstBaseURL:YES];
    components.scheme = @"file";
    components.host = @"";
    return components.URL ?: previewURL;
}

#pragma mark - WKURLSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    NSURL *requested = task.request.URL;
    NSURL *fileURL = [[self class] fileURLForPreviewURL:requested];
    NSString *path = fileURL.path;

    NSError *error = nil;
    NSData *data = nil;

    BOOL isDirectory = NO;
    if (path
        && [[NSFileManager defaultManager] fileExistsAtPath:path
                                                isDirectory:&isDirectory]
        && !isDirectory)
    {
        data = [NSData dataWithContentsOfURL:fileURL options:0 error:&error];
    }

    if (!data)
    {
        if (!error)
        {
            error = [NSError errorWithDomain:NSURLErrorDomain
                                        code:NSURLErrorFileDoesNotExist
                                    userInfo:@{NSURLErrorFailingURLErrorKey:
                                                   requested ?: [NSNull null]}];
        }
        [task didFailWithError:error];
        return;
    }

    NSString *mimeType = nil;
    if (@available(macOS 11.0, *))
    {
        UTType *type = [UTType typeWithFilenameExtension:fileURL.pathExtension];
        mimeType = type.preferredMIMEType;
    }
    if (!mimeType.length)
        mimeType = @"application/octet-stream";

    NSURLResponse *response =
        [[NSURLResponse alloc] initWithURL:requested
                                  MIMEType:mimeType
                     expectedContentLength:data.length
                          textEncodingName:nil];

    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
    // Reads are synchronous and already finished by the time this could
    // arrive, so there is nothing to cancel.
}

@end
