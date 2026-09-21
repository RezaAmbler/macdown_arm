//
//  MPRenderer.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 26/6.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPRenderer.h"
#import <limits.h>
#import <hoedown/html.h>
#import <hoedown/document.h>
#import <HBHandlebars/HBHandlebars.h>
#import "hoedown_html_patch.h"
#import "NSJSONSerialization+File.h"
#import "NSObject+HTMLTabularize.h"
#import "NSString+Lookup.h"
#import "MPUtilities.h"
#import "MPAsset.h"
#import "MPPreferences.h"

// MacDown ships a patched copy of the MathJax 2.7.3 loader (Resources/MathJax)
// that does not hang when a resource fails to load -- see
// https://github.com/mathjax/MathJax/issues/548.
//
// The legacy WebView substituted that patched loader for the CDN one by
// rewriting the request in a WebResourceLoadDelegate. WKWebView cannot
// intercept https loads, so instead the patched loader is inlined directly
// into the page and pointed at the CDN for everything else it needs (config,
// jax, fonts) via MathJax.AuthorConfig.root, which the loader honours.
//
// MathJax therefore still requires a network connection, exactly as before.
static NSString * const kMPMathJaxCDNRoot =
    @"https://cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.3";
static NSString * const kMPMathJaxConfigName = @"TeX-AMS-MML_HTMLorMML.js";
static NSString * const kMPPrismScriptDirectory = @"Prism/components";
static NSString * const kMPPrismThemeDirectory = @"Prism/themes";
static NSString * const kMPPrismPluginDirectory = @"Prism/plugins";
static size_t kMPRendererNestingLevel = SIZE_MAX;
static int kMPRendererTOCLevel = 6;  // h1 to h6.


NS_INLINE NSURL *MPExtensionURL(NSString *name, NSString *extension)
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *url = [bundle URLForResource:name withExtension:extension
                           subdirectory:@"Extensions"];
    return url;
}

NS_INLINE NSURL *MPPrismPluginURL(NSString *name, NSString *extension)
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *dirPath =
        [NSString stringWithFormat:@"%@/%@", kMPPrismPluginDirectory, name];

    NSString *filename = [NSString stringWithFormat:@"prism-%@.min", name];
    NSURL *url = [bundle URLForResource:filename withExtension:extension
                           subdirectory:dirPath];
    if (url)
        return url;

    filename = [NSString stringWithFormat:@"prism-%@", name];
    url = [bundle URLForResource:filename withExtension:extension
                    subdirectory:dirPath];
    return url;
}

NS_INLINE NSArray *MPPrismScriptURLsForLanguage(NSString *language)
{
    NSURL *baseUrl = nil;
    NSURL *extraUrl = nil;
    NSBundle *bundle = [NSBundle mainBundle];

    language = [language lowercaseString];
    NSString *baseFileName =
        [NSString stringWithFormat:@"prism-%@", language];
    NSString *extraFileName =
        [NSString stringWithFormat:@"prism-%@-extras", language];

    for (NSString *ext in @[@"min.js", @"js"])
    {
        if (!baseUrl)
        {
            baseUrl = [bundle URLForResource:baseFileName withExtension:ext
                                subdirectory:kMPPrismScriptDirectory];
        }
        if (!extraUrl)
        {
            extraUrl = [bundle URLForResource:extraFileName withExtension:ext
                                 subdirectory:kMPPrismScriptDirectory];
        }
    }

    NSMutableArray *urls = [NSMutableArray array];
    if (baseUrl)
        [urls addObject:baseUrl];
    if (extraUrl)
        [urls addObject:extraUrl];
    return urls;
}

NS_INLINE NSString *MPHTMLFromMarkdown(
    NSString *text, int flags, BOOL smartypants, NSString *frontMatter,
    hoedown_renderer *htmlRenderer, hoedown_renderer *tocRenderer)
{
    NSData *inputData = [text dataUsingEncoding:NSUTF8StringEncoding];
    hoedown_document *document = hoedown_document_new(
        htmlRenderer, flags, kMPRendererNestingLevel);
    hoedown_buffer *ob = hoedown_buffer_new(64);
    hoedown_document_render(document, ob, inputData.bytes, inputData.length);
    if (smartypants)
    {
        hoedown_buffer *ib = ob;
        ob = hoedown_buffer_new(64);
        hoedown_html_smartypants(ob, ib->data, ib->size);
        hoedown_buffer_free(ib);
    }
    NSString *result = [NSString stringWithUTF8String:hoedown_buffer_cstr(ob)];
    hoedown_document_free(document);
    hoedown_buffer_free(ob);

    if (tocRenderer)
    {
        document = hoedown_document_new(
            tocRenderer, flags, kMPRendererNestingLevel);
        ob = hoedown_buffer_new(64);
        hoedown_document_render(
            document, ob, inputData.bytes, inputData.length);
        NSString *toc = [NSString stringWithUTF8String:hoedown_buffer_cstr(ob)];

        static NSRegularExpression *tocRegex = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSString *pattern = @"<p.*?>\\s*\\[TOC\\]\\s*</p>";
            NSRegularExpressionOptions ops = NSRegularExpressionCaseInsensitive;
            tocRegex = [[NSRegularExpression alloc] initWithPattern:pattern
                                                            options:ops
                                                              error:NULL];
        });
        NSRange replaceRange = NSMakeRange(0, result.length);
        result = [tocRegex stringByReplacingMatchesInString:result options:0
                                                      range:replaceRange
                                               withTemplate:toc];
        hoedown_document_free(document);
        hoedown_buffer_free(ob);
    }

    // Give headings GitHub-style id anchors so in-document TOC links resolve.
    result = [MPRenderer HTMLByAddingHeadingAnchors:result];

    if (frontMatter)
        result = [NSString stringWithFormat:@"%@\n%@", frontMatter, result];

    return result;
}

NS_INLINE NSString *MPGetHTML(
    NSString *title, NSString *body, NSArray *styles, MPAssetOption styleopt,
    NSArray *scripts, MPAssetOption scriptopt)
{
    NSMutableArray *styleTags = [NSMutableArray array];
    NSMutableArray *scriptTags = [NSMutableArray array];
    for (MPStyleSheet *style in styles)
    {
        NSString *s = [style htmlForOption:styleopt];
        if (s)
            [styleTags addObject:s];
    }
    for (MPScript *script in scripts)
    {
        NSString *s = [script htmlForOption:scriptopt];
        if (s)
            [scriptTags addObject:s];
    }

    MPPreferences *preferences = [MPPreferences sharedInstance];

    static NSString *f = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        NSURL *url = [bundle URLForResource:preferences.htmlTemplateName
                              withExtension:@".handlebars"
                               subdirectory:@"Templates"];
        f = [NSString stringWithContentsOfURL:url
                                     encoding:NSUTF8StringEncoding error:NULL];
    });
    NSCAssert(f.length, @"Could not read template");

    NSString *titleTag = @"";
    if (title.length)
        titleTag = [NSString stringWithFormat:@"<title>%@</title>", title];

    NSDictionary *context = @{
        @"title": title ? title : @"",
        @"titleTag": titleTag ? titleTag : @"",
        @"styleTags": styleTags ? styleTags : @[],
        @"body": body ? body : @"",
        @"scriptTags": scriptTags ? scriptTags : @[],
    };
    NSString *html = [HBHandlebars renderTemplateString:f withContext:context
                                                  error:NULL];
    return html;
}

NS_INLINE BOOL MPAreNilableStringsEqual(NSString *s1, NSString *s2)
{
    // The == part takes care of cases where s1 and s2 are both nil.
    return ([s1 isEqualToString:s2] || s1 == s2);
}


@interface MPRenderer ()

@property (strong) NSMutableArray *currentLanguages;
@property (readonly) NSArray *baseStylesheets;
@property (readonly) NSArray *prismStylesheets;
@property (readonly) NSArray *prismScripts;
@property (readonly) NSArray *mathjaxScripts;
@property (readonly) NSArray *mermaidStylesheets;
@property (readonly) NSArray *mermaidScripts;
@property (readonly) NSArray *graphvizScripts;
@property (readonly) NSArray *stylesheets;
@property (readonly) NSArray *scripts;
@property (copy) NSString *currentHtml;
@property (strong) NSOperationQueue *parseQueue;
@property int extensions;
@property BOOL smartypants;
@property BOOL TOC;
@property (copy) NSString *styleName;
@property BOOL frontMatter;
@property BOOL syntaxHighlighting;
@property BOOL mermaid;
@property BOOL graphviz;
@property MPCodeBlockAccessoryType codeBlockAccesory;
@property BOOL lineNumbers;
@property BOOL manualRender;
@property (copy) NSString *highlightingThemeName;

@end


NS_INLINE void add_to_languages(
    NSString *lang, NSMutableArray *languages, NSDictionary *languageMap)
{
    // Move language to root of dependencies.
    NSUInteger index = [languages indexOfObject:lang];
    if (index != NSNotFound)
        [languages removeObjectAtIndex:index];
    [languages insertObject:lang atIndex:0];

    // Add dependencies of this language.
    id require = languageMap[lang][@"require"];
    if ([require isKindOfClass:[NSString class]])
    {
        add_to_languages(require, languages, languageMap);
    }
    else if ([require isKindOfClass:[NSArray class]])
    {
        for (NSString *lang in require)
            add_to_languages(lang, languages, languageMap);
    }
    else if (require)
    {
        NSLog(@"Unknown Prism langauge requirement "
              @"%@ dropped for unknown format", require);
    }
}


NS_INLINE hoedown_buffer *language_addition(
    const hoedown_buffer *language, void *owner)
{
    MPRenderer *renderer = (__bridge MPRenderer *)owner;
    NSString *lang = [[NSString alloc] initWithBytes:language->data
                                              length:language->size
                                            encoding:NSUTF8StringEncoding];

    static NSDictionary *aliasMap = nil;
    static NSDictionary *languageMap = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        NSURL *url = [bundle URLForResource:@"syntax_highlighting"
                              withExtension:@"json"];
        NSDictionary *info =
            [NSJSONSerialization JSONObjectWithFileAtURL:url options:0
                                                   error:NULL];

        aliasMap = info[@"aliases"];

        url = [bundle URLForResource:@"components" withExtension:@"js"
                        subdirectory:@"Prism"];
        NSString *code = [NSString stringWithContentsOfURL:url
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        NSDictionary *comp = MPGetObjectFromJavaScript(code, @"components");
        languageMap = comp[@"languages"];
    });

    // Try to identify alias and point it to the "real" language name.
    hoedown_buffer *mapped = NULL;
    if ([aliasMap objectForKey:lang])
    {
        lang = [aliasMap objectForKey:lang];
        NSData *data = [lang dataUsingEncoding:NSUTF8StringEncoding];
        mapped = hoedown_buffer_new(64);
        hoedown_buffer_put(mapped, data.bytes, data.length);
    }

    // Walk dependencies to include all required scripts.
    add_to_languages(lang, renderer.currentLanguages, languageMap);
    
    return mapped;
}

NS_INLINE hoedown_renderer *MPCreateHTMLRenderer(MPRenderer *renderer)
{
    int flags = renderer.rendererFlags;
    hoedown_renderer *htmlRenderer = hoedown_html_renderer_new(
        flags, kMPRendererTOCLevel);
    htmlRenderer->blockcode = hoedown_patch_render_blockcode;
    htmlRenderer->listitem = hoedown_patch_render_listitem;
    
    hoedown_html_renderer_state_extra *extra =
        hoedown_malloc(sizeof(hoedown_html_renderer_state_extra));
    extra->language_addition = language_addition;
    extra->owner = (__bridge void *)renderer;

    ((hoedown_html_renderer_state *)htmlRenderer->opaque)->opaque = extra;
    return htmlRenderer;
}

NS_INLINE hoedown_renderer *MPCreateHTMLTOCRenderer()
{
    hoedown_renderer *tocRenderer =
        hoedown_html_toc_renderer_new(kMPRendererTOCLevel);
    tocRenderer->header = hoedown_patch_render_toc_header;
    return tocRenderer;
}

NS_INLINE void MPFreeHTMLRenderer(hoedown_renderer *htmlRenderer)
{
    hoedown_html_renderer_state_extra *extra =
        ((hoedown_html_renderer_state *)htmlRenderer->opaque)->opaque;
    if (extra)
        free(extra);
    hoedown_html_renderer_free(htmlRenderer);
}


@implementation MPRenderer

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;

    self.currentHtml = @"";
    self.currentLanguages = [NSMutableArray array];
    self.parseQueue = [[NSOperationQueue alloc] init];
    self.parseQueue.maxConcurrentOperationCount = 1; // Serial queue

    return self;
}

#pragma mark - Accessor

- (NSArray *)baseStylesheets
{
    NSString *defaultStyleName =
        MPStylePathForName([self.delegate rendererStyleName:self]);
    if (!defaultStyleName)
        return @[];
    NSURL *defaultStyle = [NSURL fileURLWithPath:defaultStyleName];
    NSMutableArray *stylesheets = [NSMutableArray array];
    [stylesheets addObject:[MPStyleSheet CSSWithURL:defaultStyle]];
    return stylesheets;
}

- (NSArray *)prismStylesheets
{
    NSString *name = [self.delegate rendererHighlightingThemeName:self];
    MPAsset *stylesheet =
        [MPStyleSheet CSSWithURL:MPHighlightingThemeURLForName(name)];

    NSMutableArray *stylesheets = [NSMutableArray arrayWithObject:stylesheet];

    if (self.rendererFlags & HOEDOWN_HTML_BLOCKCODE_LINE_NUMBERS)
    {
        NSURL *url = MPPrismPluginURL(@"line-numbers", @"css");
        [stylesheets addObject:[MPStyleSheet CSSWithURL:url]];
    }
    if ([self.delegate rendererCodeBlockAccesory:self]
        == MPCodeBlockAccessoryLanguageName)
    {
        NSURL *url = MPPrismPluginURL(@"show-language", @"css");
        [stylesheets addObject:[MPStyleSheet CSSWithURL:url]];
    }

    return stylesheets;
}

- (NSArray *)prismScripts
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *url = [bundle URLForResource:@"prism-core.min" withExtension:@"js"
                           subdirectory:kMPPrismScriptDirectory];
    MPAsset *script = [MPScript javaScriptWithURL:url];
    NSMutableArray *scripts = [NSMutableArray arrayWithObject:script];
    for (NSString *language in self.currentLanguages)
    {
        for (NSURL *url in MPPrismScriptURLsForLanguage(language))
            [scripts addObject:[MPScript javaScriptWithURL:url]];
    }

    if (self.rendererFlags & HOEDOWN_HTML_BLOCKCODE_LINE_NUMBERS)
    {
        NSURL *url = MPPrismPluginURL(@"line-numbers", @"js");
        [scripts addObject:[MPScript javaScriptWithURL:url]];
    }
    if ([self.delegate rendererCodeBlockAccesory:self]
        == MPCodeBlockAccessoryLanguageName)
    {
        NSURL *url = MPPrismPluginURL(@"show-language", @"js");
        [scripts addObject:[MPScript javaScriptWithURL:url]];
    }
    return scripts;
}

- (NSArray *)mathjaxScripts
{
    NSMutableArray *scripts = [NSMutableArray array];
    NSBundle *bundle = [NSBundle mainBundle];

    // 1. Tell the loader where to fetch everything else from, and which
    //    config to use. This replaces the "?config=" query string the CDN
    //    URL used to carry, and must run before the loader itself.
    NSString *authorConfig =
        [NSString stringWithFormat:
            @"window.MathJax = { root: \"%@\", config: [\"%@\"] };",
            kMPMathJaxCDNRoot, kMPMathJaxConfigName];
    [scripts addObject:[MPInlineScript scriptWithContent:authorConfig]];

    // 2. MacDown's own MathJax configuration, picked up by the loader.
    [scripts addObject:
        [MPEmbeddedScript assetWithURL:[bundle URLForResource:@"init"
                                                withExtension:@"js"
                                                 subdirectory:@"MathJax"]
                               andType:kMPMathJaxConfigType]];

    // 3. The patched loader, inlined. Embedding rather than linking is what
    //    lets us keep using the patched copy now that requests can no longer
    //    be rewritten; it also means exported HTML carries the same fix.
    [scripts addObject:
        [MPEmbeddedScript assetWithURL:[bundle URLForResource:@"MathJax"
                                                withExtension:@"js"
                                                 subdirectory:@"MathJax"]
                               andType:kMPJavaScriptType]];
    return scripts;
}

- (NSArray *)mermaidStylesheets
{
    NSMutableArray *stylesheets = [NSMutableArray array];
    
    NSURL *url = MPExtensionURL(@"mermaid.forest", @"css");
    [stylesheets addObject:[MPStyleSheet CSSWithURL:url]];
    
    return stylesheets;
}

- (NSArray *)mermaidScripts
{
    // TODO
    NSMutableArray *scripts = [NSMutableArray array];

    {
        NSURL *url = MPExtensionURL(@"mermaid.min", @"js");
        [scripts addObject:[MPScript javaScriptWithURL:url]];
    }
    {
        NSURL *url = MPExtensionURL(@"mermaid.init", @"js");
        [scripts addObject:[MPScript javaScriptWithURL:url]];
    }
    
    return scripts;
}

- (NSArray *)graphvizScripts
{
    // TODO
    NSMutableArray *scripts = [NSMutableArray array];

    {
        NSURL *url = MPExtensionURL(@"viz", @"js");
        [scripts addObject:[MPScript javaScriptWithURL:url]];
    }
    {
        NSURL *url = MPExtensionURL(@"viz.init", @"js");
        [scripts addObject:[MPScript javaScriptWithURL:url]];
    }
    
    return scripts;
}

/** Whether the current document actually contains a mermaid diagram.
 *
 * -currentLanguages holds the info string of every fenced code block in the
 * document, so this is simply whether one of them is a mermaid block --
 * which is exactly what mermaid.init.js goes looking for
 * (".language-mermaid").
 */
- (BOOL)currentDocumentUsesMermaid
{
    return [self.currentLanguages containsObject:@"mermaid"];
}

/** Whether the current document actually contains a Graphviz diagram.
 *
 * viz.init.js scans for "code.language-<engine>" for each supported engine,
 * so a document uses Graphviz if it fences a block with any of those names.
 */
- (BOOL)currentDocumentUsesGraphviz
{
    static NSSet *engines = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engines = [NSSet setWithArray:@[@"circo", @"dot", @"fdp",
                                        @"neato", @"osage", @"twopi"]];
    });

    for (NSString *language in self.currentLanguages)
    {
        if ([engines containsObject:language])
            return YES;
    }
    return NO;
}

/** Whether the current document appears to contain any mathematics.
 *
 * MathJax fetches its configuration, jax and fonts from a CDN as soon as it
 * loads, so including it in a document with no formulas costs a network
 * round trip for nothing. Checking first keeps that to documents that need
 * it.
 *
 * Deliberately generous: these are the only delimiters MathJax is configured
 * for, and erring towards including it merely wastes a request, whereas
 * leaving it out of a document that needs it would fail to typeset.
 */
- (BOOL)currentDocumentUsesMathJax
{
    NSString *html = self.currentHtml;
    if (!html.length)
        return NO;

    if ([html rangeOfString:@"$$"].location != NSNotFound
        || [html rangeOfString:@"\\("].location != NSNotFound
        || [html rangeOfString:@"\\["].location != NSNotFound)
        return YES;

    // With inline-dollar enabled a single "$" pair also delimits math.
    if ([MPPreferences sharedInstance].htmlMathJaxInlineDollar
        && [html rangeOfString:@"$"].location != NSNotFound)
        return YES;

    return NO;
}

- (NSArray *)stylesheets
{
    id<MPRendererDelegate> delegate = self.delegate;

    NSMutableArray *stylesheets = [self.baseStylesheets mutableCopy];
    if ([delegate rendererHasSyntaxHighlighting:self])
    {
        [stylesheets addObjectsFromArray:self.prismStylesheets];
        // mermaid
        if ([delegate rendererHasMermaid:self] && self.currentDocumentUsesMermaid)
        {
            [stylesheets addObjectsFromArray:self.mermaidStylesheets];
        }

    }

    if ([delegate rendererCodeBlockAccesory:self] == MPCodeBlockAccessoryCustom)
    {
        NSURL *url = MPExtensionURL(@"show-information", @"css");
        [stylesheets addObject:[MPStyleSheet CSSWithURL:url]];
    }
    return stylesheets;
}

- (NSArray *)scripts
{
    id<MPRendererDelegate> d = self.delegate;
    NSMutableArray *scripts = [NSMutableArray array];
    if (self.rendererFlags & HOEDOWN_HTML_USE_TASK_LIST)
    {
        NSURL *url = MPExtensionURL(@"tasklist", @"js");
        [scripts addObject:[MPScript javaScriptWithURL:url]];
    }
    if ([d rendererHasSyntaxHighlighting:self])
    {
        [scripts addObjectsFromArray:self.prismScripts];

        // These two are only pulled in when the document actually contains a
        // diagram. mermaid.min.js is 1.1 MB and viz.js is 3.6 MB, and assets
        // are inlined into the page rather than linked, so including them
        // unconditionally would put nearly 5 MB into every render -- which
        // happens roughly twice a second while typing. Gating on content is
        // what makes it reasonable for these to be on by default.
        if ([d rendererHasMermaid:self] && self.currentDocumentUsesMermaid)
        {
            [scripts addObjectsFromArray:self.mermaidScripts];
        }
        if ([d rendererHasGraphviz:self] && self.currentDocumentUsesGraphviz)
        {
            [scripts addObjectsFromArray:self.graphvizScripts];
        }
    }
    if ([d rendererHasMathJax:self])
        [scripts addObjectsFromArray:self.mathjaxScripts];
    return scripts;
}

#pragma mark - Public
    
- (void)parseAndRenderWithMaxDelay:(NSTimeInterval)maxDelay {
    [self.parseQueue cancelAllOperations];
    [self.parseQueue addOperationWithBlock:^{
        // Fetch the markdown (from the main thread)
        __block NSString *markdown;
        dispatch_sync(dispatch_get_main_queue(), ^{
            markdown = [[self.dataSource rendererMarkdown:self] copy];
        });

        // Parse in backgound
        [self parseMarkdown:markdown];
        
        // Wait until the preview has finished loading, or until maxDelay has
        // passed. This results in overall faster update times.
        //
        // The timeout used to be written as `[start timeIntervalSinceNow] >=
        // maxDelay`, combined with ||. timeIntervalSinceNow counts backwards
        // from a date in the past, so that term was negative and maxDelay
        // positive: it was never true, and the condition collapsed to "loop
        // while loading", with no timeout and nothing yielding the CPU.
        //
        // That was merely wasteful with the old WebView. With WKWebView the
        // page is rendered by a separate process that can stall or be
        // jettisoned, leaving isLoading stuck at YES -- and this is a
        // background thread spinning dispatch_sync against the main queue,
        // so it would peg a core indefinitely.
        //
        // Waiting is only an optimisation in any case: a render that arrives
        // mid-load is held by alreadyRenderingInWeb and replayed when the
        // navigation finishes.
        NSDate *start = [NSDate date];
        __block BOOL rendererIsLoading = YES;
        while (rendererIsLoading && -[start timeIntervalSinceNow] < maxDelay) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                rendererIsLoading = [self.dataSource rendererLoading];
            });
            if (rendererIsLoading)
                usleep(5000);
        }
        
        // Render on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self render];
        });
    }];
}

- (void)parseAndRenderNow
{
    [self parseAndRenderWithMaxDelay:0];
}

- (void)parseAndRenderLater
{
    [self parseAndRenderWithMaxDelay:0.5];
}

- (void)parseIfPreferencesChanged
{
    id<MPRendererDelegate> delegate = self.delegate;
    if ([delegate rendererExtensions:self] != self.extensions
            || [delegate rendererHasSmartyPants:self] != self.smartypants
            || [delegate rendererRendersTOC:self] != self.TOC
            || [delegate rendererDetectsFrontMatter:self] != self.frontMatter)
    {
        [self parseMarkdown:[self.dataSource rendererMarkdown:self]];
    }
}

- (void)parseMarkdown:(NSString *)markdown {
    [self.currentLanguages removeAllObjects];
    
    id<MPRendererDelegate> delegate = self.delegate;
    int extensions = [delegate rendererExtensions:self];
    BOOL smartypants = [delegate rendererHasSmartyPants:self];
    BOOL hasFrontMatter = [delegate rendererDetectsFrontMatter:self];
    BOOL hasTOC = [delegate rendererRendersTOC:self];
    
    id frontMatter = nil;
    if (hasFrontMatter)
    {
        NSUInteger offset = 0;
        frontMatter = [markdown frontMatter:&offset];
        markdown = [markdown substringFromIndex:offset];
    }
    hoedown_renderer *htmlRenderer = MPCreateHTMLRenderer(self);
    hoedown_renderer *tocRenderer = NULL;
    if (hasTOC)
    tocRenderer = MPCreateHTMLTOCRenderer();
    self.currentHtml = MPHTMLFromMarkdown(
                                          markdown, extensions, smartypants, [frontMatter HTMLTable],
                                          htmlRenderer, tocRenderer);
    if (tocRenderer)
    hoedown_html_renderer_free(tocRenderer);
    MPFreeHTMLRenderer(htmlRenderer);
    
    self.extensions = extensions;
    self.smartypants = smartypants;
    self.TOC = hasTOC;
    self.frontMatter = hasFrontMatter;
}

- (void)renderIfPreferencesChanged
{
    BOOL changed = NO;
    id<MPRendererDelegate> d = self.delegate;
    if ([d rendererHasSyntaxHighlighting:self] != self.syntaxHighlighting)
        changed = YES;
    else if ([d rendererHasMermaid:self] != self.mermaid)
        changed = YES;
    else if ([d rendererHasGraphviz:self] != self.graphviz)
        changed = YES;
    else if (!MPAreNilableStringsEqual(
            [d rendererHighlightingThemeName:self], self.highlightingThemeName))
        changed = YES;
    else if (!MPAreNilableStringsEqual(
            [d rendererStyleName:self], self.styleName))
        changed = YES;
    else if ([d rendererCodeBlockAccesory:self] != self.codeBlockAccesory)
        changed = YES;

    if (changed)
        [self render];
}

- (void)render
{
    id<MPRendererDelegate> delegate = self.delegate;

    NSString *title = [self.dataSource rendererHTMLTitle:self];

    // Assets are inlined rather than linked. WKWebView will not load local
    // file subresources for every configuration we care about, and inlining
    // sidesteps the question entirely. MathJax is a remote CDN URL, so it
    // keeps falling through to a <script src> -- see -mathjaxScripts.
    // MPAsset caches file contents, so this does not re-read from disk on
    // every keystroke.
    NSString *html = MPGetHTML(
        title, self.currentHtml, self.stylesheets, MPAssetEmbedded,
        self.scripts, MPAssetEmbedded);
    [delegate renderer:self didProduceHTMLOutput:html];

    self.styleName = [delegate rendererStyleName:self];
    self.syntaxHighlighting = [delegate rendererHasSyntaxHighlighting:self];
    self.mermaid = [delegate rendererHasMermaid:self];
    self.graphviz = [delegate rendererHasGraphviz:self];
    self.highlightingThemeName = [delegate rendererHighlightingThemeName:self];
    self.codeBlockAccesory = [delegate rendererCodeBlockAccesory:self];
}

- (NSString *)HTMLForExportWithStyles:(BOOL)withStyles
                         highlighting:(BOOL)withHighlighting
{
    MPAssetOption stylesOption = MPAssetNone;
    MPAssetOption scriptsOption = MPAssetNone;
    NSMutableArray *styles = [NSMutableArray array];
    NSMutableArray *scripts = [NSMutableArray array];

    if (withStyles)
    {
        stylesOption = MPAssetEmbedded;
        [styles addObjectsFromArray:self.baseStylesheets];
    }
    if (withHighlighting)
    {
        stylesOption = MPAssetEmbedded;
        scriptsOption = MPAssetEmbedded;
        [styles addObjectsFromArray:self.prismStylesheets];
        [scripts addObjectsFromArray:self.prismScripts];
        if ([self.delegate rendererHasMermaid:self])
        {
            [styles addObjectsFromArray:self.mermaidStylesheets];
            [scripts addObjectsFromArray:self.mermaidScripts];
        }
        if ([self.delegate rendererHasGraphviz:self])
        {
            [scripts addObjectsFromArray:self.graphvizScripts];
        }

    }
    if ([self.delegate rendererHasMathJax:self])
    {
        scriptsOption = MPAssetEmbedded;
        [scripts addObjectsFromArray:self.mathjaxScripts];
    }

    NSString *title = [self.dataSource rendererHTMLTitle:self];
    if (!title)
        title = @"";
    NSString *html = MPGetHTML(
        title, self.currentHtml, styles, stylesOption, scripts, scriptsOption);
    return html;
}

#pragma mark - Heading anchors

+ (NSString *)anchorSlugForHeadingText:(NSString *)text
{
    // GitHub-compatible slug: lowercase, keep letters/digits/'-'/'_', turn
    // spaces into hyphens, drop everything else. e.g.
    //   "1. Product Overview"            -> "1-product-overview"
    //   "6. Authentication & Authorization" -> "6-authentication--authorization"
    NSString *lower = [text lowercaseString];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    NSMutableString *slug = [NSMutableString stringWithCapacity:lower.length];
    [lower enumerateSubstringsInRange:NSMakeRange(0, lower.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        unichar first = [ch characterAtIndex:0];
        if ([ch rangeOfCharacterFromSet:alnum].location != NSNotFound
                || first == '-' || first == '_')
            [slug appendString:ch];
        else if (first == ' ')
            [slug appendString:@"-"];
        // anything else (punctuation) is dropped
    }];
    return [slug copy];
}

// Strips inline tags and decodes the handful of entities hoedown emits, so a
// heading's text matches what the user sees (and what GitHub would slug).
+ (NSString *)plainTextFromHeadingHTML:(NSString *)html
{
    static NSRegularExpression *tagRegex = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        tagRegex = [[NSRegularExpression alloc] initWithPattern:@"<[^>]+>"
                                                        options:0 error:NULL];
    });
    NSString *text = [tagRegex stringByReplacingMatchesInString:html options:0
                            range:NSMakeRange(0, html.length) withTemplate:@""];
    text = [text stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    text = [text stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    text = [text stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    text = [text stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    text = [text stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
    // &amp; last so "&amp;lt;" doesn't become "<".
    text = [text stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return text;
}

+ (NSString *)HTMLByAddingHeadingAnchors:(NSString *)html
{
    if (!html.length)
        return html;

    static NSRegularExpression *headingRegex = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        // <hN ...attrs...>inner</hN>, attrs and inner captured.
        NSRegularExpressionOptions ops = NSRegularExpressionCaseInsensitive
            | NSRegularExpressionDotMatchesLineSeparators;
        headingRegex = [[NSRegularExpression alloc]
            initWithPattern:@"<h([1-6])([^>]*)>(.*?)</h\\1>" options:ops error:NULL];
    });

    NSArray<NSTextCheckingResult *> *matches =
        [headingRegex matchesInString:html options:0
                                range:NSMakeRange(0, html.length)];
    if (!matches.count)
        return html;

    // First pass (document order): compute slugs, de-duplicating repeats.
    // hoedown already gives headings an id="toc_N" (used by the [TOC] feature),
    // so rather than touch that we insert an empty anchor at the start of the
    // heading's content to carry the slug — additive and non-breaking.
    NSCountedSet *seen = [NSCountedSet set];
    NSMutableArray<NSNumber *> *locations = [NSMutableArray array];
    NSMutableArray<NSString *> *anchors = [NSMutableArray array];
    for (NSTextCheckingResult *match in matches)
    {
        NSString *inner = [html substringWithRange:[match rangeAtIndex:3]];
        NSString *base =
            [self anchorSlugForHeadingText:[self plainTextFromHeadingHTML:inner]];
        if (!base.length)
            continue;

        NSUInteger n = [seen countForObject:base];
        [seen addObject:base];
        NSString *slug = n ? [NSString stringWithFormat:@"%@-%lu",
                              base, (unsigned long)n] : base;

        [locations addObject:@([match rangeAtIndex:3].location)];
        [anchors addObject:[NSString stringWithFormat:
            @"<a class=\"md-heading-anchor\" id=\"%@\"></a>", slug]];
    }

    // Second pass (reverse): insert from the end so earlier offsets stay valid.
    NSMutableString *out = [html mutableCopy];
    for (NSInteger i = locations.count - 1; i >= 0; i--)
        [out insertString:anchors[i]
                  atIndex:locations[i].unsignedIntegerValue];
    return [out copy];
}

@end
