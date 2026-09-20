//
//  MPDocument.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 6/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPDocument.h"
#import <WebKit/WebKit.h>
#import <JJPluralForm/JJPluralForm.h>
#import <hoedown/html.h>
#import "hoedown_html_patch.h"
#import "HGMarkdownHighlighter.h"
#import "MPUtilities.h"
#import "MPAutosaving.h"
#import "NSColor+HTML.h"
#import "NSDocumentController+Document.h"
#import "NSPasteboard+Types.h"
#import "NSString+Lookup.h"
#import "NSTextView+Autocomplete.h"
#import "NSString+WordCount.h"
#import "MPPreferences.h"
#import "MPDocumentSplitView.h"
#import "MPEditorView.h"
#import "MPRenderer.h"
#import "MPPreferencesViewController.h"
#import "MPEditorPreferencesViewController.h"
#import "MPExportPanelAccessoryViewController.h"
#import "MPPreviewWebView.h"
#import "MPPreviewSchemeHandler.h"
#import "MPWeakScriptMessageHandler.h"
#import "MPToolbarController.h"
#import "MPGlobals.h"

static NSString * const kMPDefaultAutosaveName = @"Untitled";

// Script message handler names, shared with kMPPreviewBridgeScript below.
static NSString * const kMPMathJaxListenerName = @"MathJaxListener";
static NSString * const kMPPreviewScrollName = @"previewScroll";

// How long to wait for MathJax to report that it has finished typesetting
// before running the load-completion work anyway. MathJax pulls its jax and
// fonts from a CDN, so offline (or a blocked network) the "End" hook never
// fires and without this the preview would never be zoomed or scroll-synced.
static const NSTimeInterval kMPMathJaxCompletionTimeout = 5.0;

/**
 * Injected into every preview page as a WKUserScript.
 *
 * Everything the native side used to read straight off the DOM or the web
 * view's scroll view has to be funnelled through this, because WKWebView runs
 * the page out of process and gives us no synchronous access to either.
 *
 * -metrics returns all of it in a single round trip: asking separately would
 * cost an IPC each, and these are read together on every scroll-sync pass.
 *
 * -scrollTo forces instant scrolling. The default template sets
 * `html { scroll-behavior: smooth }` for the in-document TOC links, which
 * would otherwise animate every synced scroll step and make the preview lag
 * behind the editor.
 */
static NSString * const kMPPreviewBridgeScript = @""
    "window.__mp = {"
    "  metrics: function () {"
    "    var y = window.scrollY, out = [];"
    "    var nodes = document.querySelectorAll('h1, h2, h3, h4, h5, h6, img:only-child');"
    "    for (var i = 0; i < nodes.length; i++)"
    "      out.push(nodes[i].getBoundingClientRect().top + y);"
    "    return { headers: out,"
    "             contentHeight: document.documentElement.scrollHeight,"
    "             visibleHeight: window.innerHeight,"
    "             scrollY: y,"
    "             background: getComputedStyle(document.body).backgroundColor };"
    "  },"
    "  scrollTo: function (y) {"
    "    var s = document.documentElement.style, prev = s.scrollBehavior;"
    "    s.scrollBehavior = 'auto';"
    "    window.scrollTo(0, y);"
    "    s.scrollBehavior = prev;"
    "  },"
    // Gather the text the word/character counters run over, mirroring what
    // the old DOMNode+Text walk did: script, style and head are skipped; a
    // code block (PRE > CODE) contributes no words; an inline CODE with any
    // content counts as exactly one word.
    //
    // Two strings come back because the rules differ. Words are joined with
    // spaces, which reproduces summing each text node's count separately --
    // concatenating would fuse words across element boundaries. Characters
    // are concatenated raw, since the old code summed raw lengths.
    "  textForCount: function () {"
    "    var words = [], chars = [];"
    "    (function walk(node, inCodeBlock) {"
    "      for (var n = node.firstChild; n; n = n.nextSibling) {"
    "        if (n.nodeType === 1) {"
    "          var tag = n.tagName ? n.tagName.toUpperCase() : '';"
    "          if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'HEAD')"
    "            continue;"
    "          if (tag === 'CODE') {"
    "            var parent = n.parentNode;"
    "            var parentTag = (parent && parent.tagName)"
    "                            ? parent.tagName.toUpperCase() : '';"
    "            if (parentTag === 'PRE') {"
    "              walk(n, true);"
    "              continue;"
    "            }"
    "            if (n.textContent && n.textContent.length) words.push('x');"
    "            walk(n, true);"
    "            continue;"
    "          }"
    "          walk(n, inCodeBlock);"
    "        } else if (n.nodeType === 3 || n.nodeType === 4) {"
    "          var v = n.nodeValue || '';"
    "          chars.push(v);"
    "          if (!inCodeBlock) words.push(v);"
    "        }"
    "      }"
    "    })(document, false);"
    "    return { words: words.join(' '), chars: chars.join('') };"
    "  }"
    "};"
    // Report the preview's scroll position, coalesced to one message per
    // frame. Used only to remember where the user left the preview.
    "(function () {"
    "  var pending = 0;"
    "  window.addEventListener('scroll', function () {"
    "    if (pending) return;"
    "    pending = requestAnimationFrame(function () {"
    "      pending = 0;"
    "      if (window.webkit && window.webkit.messageHandlers"
    "          && window.webkit.messageHandlers.previewScroll)"
    "        window.webkit.messageHandlers.previewScroll.postMessage(window.scrollY);"
    "    });"
    "  }, { passive: true });"
    "})();";

// Editor font-zoom bounds and the default size used by "Actual Size".
// kMPDefaultEditorFontPointSize mirrors the value in MPPreferences.m (not
// exported), kept in sync here intentionally.
static CGFloat const kMPEditorFontPointSizeDefault = 14.0;
static CGFloat const kMPEditorFontPointSizeMin = 6.0;
static CGFloat const kMPEditorFontPointSizeMax = 72.0;


NS_INLINE NSString *MPEditorPreferenceKeyWithValueKey(NSString *key)
{
    if (!key.length)
        return @"editor";
    NSString *first = [[key substringToIndex:1] uppercaseString];
    NSString *rest = [key substringFromIndex:1];
    return [NSString stringWithFormat:@"editor%@%@", first, rest];
}

NS_INLINE NSDictionary *MPEditorKeysToObserve()
{
    static NSDictionary *keys = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        keys = @{@"automaticDashSubstitutionEnabled": @NO,
                 @"automaticDataDetectionEnabled": @NO,
                 @"automaticQuoteSubstitutionEnabled": @NO,
                 @"automaticSpellingCorrectionEnabled": @NO,
                 @"automaticTextReplacementEnabled": @NO,
                 @"continuousSpellCheckingEnabled": @NO,
                 @"enabledTextCheckingTypes": @(NSTextCheckingAllTypes),
                 @"grammarCheckingEnabled": @NO};
    });
    return keys;
}

NS_INLINE NSSet *MPEditorPreferencesToObserve()
{
    static NSSet *keys = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        keys = [NSSet setWithObjects:
            @"editorBaseFontInfo", @"extensionFootnotes",
            @"editorHorizontalInset", @"editorVerticalInset",
            @"editorWidthLimited", @"editorMaximumWidth", @"editorLineSpacing",
            @"editorOnRight", @"editorStyleName", @"editorShowWordCount",
            @"editorScrollsPastEnd", nil
        ];
    });
    return keys;
}

NS_INLINE NSString *MPRectStringForAutosaveName(NSString *name)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *key = [NSString stringWithFormat:@"NSWindow Frame %@", name];
    NSString *rectString = [defaults objectForKey:key];
    return rectString;
}

@implementation NSURL (Convert)

- (NSString *)absoluteBaseURLString
{
    // Remove fragment (#anchor) and query string.
    NSString *base = self.absoluteString;
    base = [base componentsSeparatedByString:@"?"].firstObject;
    base = [base componentsSeparatedByString:@"#"].firstObject;
    return base;
}

@end


@implementation MPPreferences (Hoedown)
- (int)extensionFlags
{
    int flags = 0;
    if (self.extensionAutolink)
        flags |= HOEDOWN_EXT_AUTOLINK;
    if (self.extensionFencedCode)
        flags |= HOEDOWN_EXT_FENCED_CODE;
    if (self.extensionFootnotes)
        flags |= HOEDOWN_EXT_FOOTNOTES;
    if (self.extensionHighlight)
        flags |= HOEDOWN_EXT_HIGHLIGHT;
    if (!self.extensionIntraEmphasis)
        flags |= HOEDOWN_EXT_NO_INTRA_EMPHASIS;
    if (self.extensionQuote)
        flags |= HOEDOWN_EXT_QUOTE;
    if (self.extensionStrikethough)
        flags |= HOEDOWN_EXT_STRIKETHROUGH;
    if (self.extensionSuperscript)
        flags |= HOEDOWN_EXT_SUPERSCRIPT;
    if (self.extensionTables)
        flags |= HOEDOWN_EXT_TABLES;
    if (self.extensionUnderline)
        flags |= HOEDOWN_EXT_UNDERLINE;
    if (self.htmlMathJax)
        flags |= HOEDOWN_EXT_MATH;
    if (self.htmlMathJaxInlineDollar)
        flags |= HOEDOWN_EXT_MATH_EXPLICIT;
    return flags;
}

- (int)rendererFlags
{
    int flags = 0;
    if (self.htmlTaskList)
        flags |= HOEDOWN_HTML_USE_TASK_LIST;
    if (self.htmlLineNumbers)
        flags |= HOEDOWN_HTML_BLOCKCODE_LINE_NUMBERS;
    if (self.htmlHardWrap)
        flags |= HOEDOWN_HTML_HARD_WRAP;
    if (self.htmlCodeBlockAccessory == MPCodeBlockAccessoryCustom)
        flags |= HOEDOWN_HTML_BLOCKCODE_INFORMATION;
    return flags;
}
@end


@interface MPDocument ()
    <NSSplitViewDelegate, NSTextViewDelegate,
     WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
     MPAutosaving, MPRendererDataSource, MPRendererDelegate>

typedef NS_ENUM(NSUInteger, MPWordCountType) {
    MPWordCountTypeWord,
    MPWordCountTypeCharacter,
    MPWordCountTypeCharacterNoSpaces,
};

@property (weak) IBOutlet NSToolbar *toolbar;
@property (weak) IBOutlet MPDocumentSplitView *splitView;
@property (weak) IBOutlet NSView *editorContainer;
@property (unsafe_unretained) IBOutlet MPEditorView *editor;
@property (weak) IBOutlet NSLayoutConstraint *editorPaddingBottom;
// The xib holds a plain container view; the web view is created in code
// because it needs a WKWebViewConfiguration (message handlers, user script,
// data store) that Interface Builder cannot express.
@property (weak) IBOutlet NSView *previewContainer;
@property (strong) MPPreviewWebView *preview;
@property (weak) IBOutlet NSPopUpButton *wordCountWidget;
@property (strong) IBOutlet MPToolbarController *toolbarController;
@property (copy, nonatomic) NSString *autosaveName;
@property (strong) HGMarkdownHighlighter *highlighter;
@property (strong) MPRenderer *renderer;
@property CGFloat previousSplitRatio;
@property BOOL manualRender;
@property BOOL copying;
@property BOOL printing;
@property BOOL shouldHandleBoundsChange;
@property BOOL isPreviewReady;
@property (strong) NSURL *currentBaseUrl;
@property CGFloat lastPreviewScrollTop;
@property (nonatomic, readonly) BOOL needsHtml;
@property (nonatomic) NSUInteger totalWords;
@property (nonatomic) NSUInteger totalCharacters;
@property (nonatomic) NSUInteger totalCharactersNoSpaces;
@property (strong) NSMenuItem *wordsMenuItem;
@property (strong) NSMenuItem *charMenuItem;
@property (strong) NSMenuItem *charNoSpacesMenuItem;
@property (nonatomic) BOOL needsToUnregister;
@property (nonatomic) BOOL alreadyRenderingInWeb;
@property (nonatomic) BOOL renderToWebPending;
@property (strong) NSArray<NSNumber *> *webViewHeaderLocations;
@property (strong) NSArray<NSNumber *> *editorHeaderLocations;
@property (nonatomic) BOOL inLiveScroll;

// The navigation currently being loaded. WKWebView cancels a navigation that
// is superseded by another load, and still reports both through the delegate,
// so callbacks have to be matched against this to know which one they concern.
@property (strong) WKNavigation *currentNavigation;
@property (strong) MPPreviewSchemeHandler *schemeHandler;

// Preview state that used to be read synchronously off the DOM or the web
// view's scroll view, now fetched via JS and cached here.
@property (strong) NSColor *previewBackgroundColor;
@property CGFloat previewContentHeight;
@property CGFloat previewVisibleHeight;
@property BOOL previewMetricsInFlight;
@property BOOL previewMetricsDirty;
@property CGFloat pendingPreviewScrollY;
@property BOOL previewScrollFlushScheduled;
@property BOOL previewCompletionHandled;

// Store file content in initializer until nib is loaded.
@property (copy) NSString *loadedString;

- (void)scaleWebview;
- (void)syncScrollers;
-(void) updateHeaderLocations;
- (void)previewDidFinishLoadingForScrollSync;
- (void)requestPreviewMetricsWithCompletion:(void (^)(void))completion;

@end

static void (^MPGetPreviewLoadingCompletionHandler(MPDocument *doc))(void)
{
    __weak MPDocument *weakObj = doc;
    return ^{
        MPDocument *obj = weakObj;
        if (!obj || !obj.preview)
            return;

        // MathJax's "End" hook and the timeout fallback can both fire; only
        // the first one through does the work.
        if (obj.previewCompletionHandled)
            return;
        obj.previewCompletionHandled = YES;

        // Zoom first: it changes the layout, so any metrics read before it
        // would be stale.
        [obj scaleWebview];
        [obj previewDidFinishLoadingForScrollSync];
    };
}


@implementation MPDocument

#pragma mark - Preview web view

- (void)setupPreviewWebView
{
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];

    // The preview is regenerated from the document on every render, so there
    // is nothing worth persisting. This also replaces the old private
    // [WebCache setDisabled:YES] call in MPMainController.
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];

    // Render the page in one go rather than progressively. Without this a
    // re-render briefly shows a partially styled page, which on the dark
    // styles reads as a white flash.
    configuration.suppressesIncrementalRendering = YES;

    WKUserContentController *controller = configuration.userContentController;
    MPWeakScriptMessageHandler *handler =
        [[MPWeakScriptMessageHandler alloc] initWithTarget:self];
    [controller addScriptMessageHandler:handler name:kMPMathJaxListenerName];
    [controller addScriptMessageHandler:handler name:kMPPreviewScrollName];

    WKUserScript *bridge =
        [[WKUserScript alloc] initWithSource:kMPPreviewBridgeScript
                               injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                            forMainFrameOnly:YES];
    [controller addUserScript:bridge];

    // Serves images and anything else the document references relatively.
    // WKWebView refuses to load file: subresources for a page created with
    // -loadHTMLString:baseURL:, so the preview is loaded under a private
    // scheme instead and those reads come back through this handler.
    self.schemeHandler = [[MPPreviewSchemeHandler alloc] init];
    [configuration setURLSchemeHandler:self.schemeHandler
                          forURLScheme:kMPPreviewURLScheme];

    MPPreviewWebView *webView =
        [[MPPreviewWebView alloc] initWithFrame:self.previewContainer.bounds
                                  configuration:configuration];
    webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    webView.navigationDelegate = self;
    webView.UIDelegate = self;

    // Pinch-zoom would fight the font-zoom commands, which drive pageZoom.
    webView.allowsMagnification = NO;

#ifdef DEBUG
    if (@available(macOS 13.3, *))
        webView.inspectable = YES;
#endif

    [self.previewContainer addSubview:webView];
    self.preview = webView;
}

#pragma mark - Accessor

- (MPPreferences *)preferences
{
    return [MPPreferences sharedInstance];
}

- (NSString *)markdown
{
    return self.editor.string;
}

- (void)setMarkdown:(NSString *)markdown
{
    self.editor.string = markdown;
}

- (NSString *)html
{
    return self.renderer.currentHtml;
}

- (BOOL)toolbarVisible
{
    return self.windowForSheet.toolbar.visible;
}

- (BOOL)previewVisible
{
    return (self.previewContainer.frame.size.width != 0.0);
}

- (BOOL)editorVisible
{
    return (self.editorContainer.frame.size.width != 0.0);
}

- (BOOL)needsHtml
{
    if (self.preferences.markdownManualRender)
        return NO;
    return (self.previewVisible || self.preferences.editorShowWordCount);
}

- (void)setTotalWords:(NSUInteger)value
{
    _totalWords = value;
    NSString *key = NSLocalizedString(@"WORDS_PLURAL_STRING", @"");
    NSInteger rule = kJJPluralFormRule.integerValue;
    self.wordsMenuItem.title =
        [JJPluralForm pluralStringForNumber:value withPluralForms:key
                            usingPluralRule:rule localizeNumeral:NO];
}

- (void)setTotalCharacters:(NSUInteger)value
{
    _totalCharacters = value;
    NSString *key = NSLocalizedString(@"CHARACTERS_PLURAL_STRING", @"");
    NSInteger rule = kJJPluralFormRule.integerValue;
    self.charMenuItem.title =
        [JJPluralForm pluralStringForNumber:value withPluralForms:key
                            usingPluralRule:rule localizeNumeral:NO];
}

- (void)setTotalCharactersNoSpaces:(NSUInteger)value
{
    _totalCharactersNoSpaces = value;
    NSString *key = NSLocalizedString(@"CHARACTERS_NO_SPACES_PLURAL_STRING",
                                      @"");
    NSInteger rule = kJJPluralFormRule.integerValue;
    self.charNoSpacesMenuItem.title =
        [JJPluralForm pluralStringForNumber:value withPluralForms:key
                            usingPluralRule:rule localizeNumeral:NO];
}

- (void)setAutosaveName:(NSString *)autosaveName
{
    _autosaveName = autosaveName;
    self.splitView.autosaveName = autosaveName;
}


#pragma mark - Override

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;

    self.isPreviewReady = NO;
    self.shouldHandleBoundsChange = YES;
    self.previousSplitRatio = -1.0;
    
    return self;
}

- (NSString *)windowNibName
{
    return @"MPDocument";
}

- (void)windowControllerDidLoadNib:(NSWindowController *)controller
{
    [super windowControllerDidLoadNib:controller];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // All files use their absolute path to keep their window states.
    NSString *autosaveName = kMPDefaultAutosaveName;
    if (self.fileURL)
        autosaveName = self.fileURL.absoluteString;
    controller.window.frameAutosaveName = autosaveName;
    self.autosaveName = autosaveName;

    // Perform initial resizing manually because for some reason untitled
    // documents do not pick up the autosaved frame automatically in 10.10.
    NSString *rectString = MPRectStringForAutosaveName(autosaveName);
    if (!rectString)
        rectString = MPRectStringForAutosaveName(kMPDefaultAutosaveName);
    if (rectString)
        [controller.window setFrameFromString:rectString];

    self.highlighter =
        [[HGMarkdownHighlighter alloc] initWithTextView:self.editor
                                           waitInterval:0.0];
    self.renderer = [[MPRenderer alloc] init];
    self.renderer.dataSource = self;
    self.renderer.delegate = self;

    for (NSString *key in MPEditorPreferencesToObserve())
    {
        [defaults addObserver:self forKeyPath:key
                      options:NSKeyValueObservingOptionNew context:NULL];
    }
    for (NSString *key in MPEditorKeysToObserve())
    {
        [self.editor addObserver:self forKeyPath:key
                         options:NSKeyValueObservingOptionNew context:NULL];
    }

    self.editor.postsFrameChangedNotifications = YES;
    [self setupPreviewWebView];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(editorTextDidChange:)
                   name:NSTextDidChangeNotification object:self.editor];
    [center addObserver:self selector:@selector(userDefaultsDidChange:)
                   name:NSUserDefaultsDidChangeNotification
                 object:[NSUserDefaults standardUserDefaults]];
    [center addObserver:self selector:@selector(editorBoundsDidChange:)
                   name:NSViewBoundsDidChangeNotification
                 object:self.editor.enclosingScrollView.contentView];
    [center addObserver:self selector:@selector(editorFrameDidChange:)
                   name:NSViewFrameDidChangeNotification object:self.editor];
    [center addObserver:self selector:@selector(didRequestEditorReload:)
                   name:MPDidRequestEditorSetupNotification object:nil];
    [center addObserver:self selector:@selector(didRequestPreviewReload:)
                   name:MPDidRequestPreviewRenderNotification object:nil];
    [center addObserver:self selector:@selector(willStartLiveScroll:)
                   name:NSScrollViewWillStartLiveScrollNotification
                 object:self.editor.enclosingScrollView];
    [center addObserver:self selector:@selector(didEndLiveScroll:)
                   name:NSScrollViewDidEndLiveScrollNotification
                 object:self.editor.enclosingScrollView];
    // The preview's scroll position now arrives through the "previewScroll"
    // script message instead of a scroll-view notification. Registering an
    // observer here would be worse than useless: a WKWebView has no
    // enclosing scroll view, so the object: argument would be nil and the
    // observer would fire for the editor's scroll view too.

    self.needsToUnregister = YES;

    self.wordsMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:NULL
                                             keyEquivalent:@""];
    self.charMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:NULL
                                            keyEquivalent:@""];
    self.charNoSpacesMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                           action:NULL
                                                    keyEquivalent:@""];

    NSPopUpButton *wordCountWidget = self.wordCountWidget;
    [wordCountWidget removeAllItems];
    [wordCountWidget.menu addItem:self.wordsMenuItem];
    [wordCountWidget.menu addItem:self.charMenuItem];
    [wordCountWidget.menu addItem:self.charNoSpacesMenuItem];
    [wordCountWidget selectItemAtIndex:self.preferences.editorWordCountType];
    wordCountWidget.alphaValue = 0.9;
    wordCountWidget.hidden = !self.preferences.editorShowWordCount;
    wordCountWidget.enabled = NO;

    // These needs to be queued until after the window is shown, so that editor
    // can have the correct dimention for size-limiting and stuff. See
    // https://github.com/uranusjr/macdown/issues/236
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [self setupEditor:nil];
        [self redrawDivider];
        [self reloadFromLoadedString];
        // The editor/preview styles persist on their own; only the window
        // chrome needs reapplying to match the saved appearance mode.
        [self applyWindowAppearanceForViewMode:self.preferences.appViewMode];
    }];
}

- (void)reloadFromLoadedString
{
    if (self.loadedString && self.editor && self.renderer && self.highlighter)
    {
        self.editor.string = self.loadedString;
        self.loadedString = nil;
        [self.renderer parseAndRenderNow];
        [self.highlighter parseAndHighlightNow];
    }
}

- (void)close
{
    if (self.needsToUnregister) 
    {
        // Close can be called multiple times, but this can only be done once.
        // http://www.cocoabuilder.com/archive/cocoa/240166-nsdocument-close-method-calls-itself.html
        self.needsToUnregister = NO;

        // Need to cleanup these so that callbacks won't crash the app.
        [self.highlighter deactivate];
        self.highlighter.targetTextView = nil;
        self.highlighter = nil;
        self.renderer = nil;

        // Tear the web view down explicitly. The content controller retains
        // its message handlers, and an in-flight load would keep calling
        // delegate methods on a document that is going away.
        [self.preview stopLoading];
        self.preview.navigationDelegate = nil;
        self.preview.UIDelegate = nil;
        WKUserContentController *controller =
            self.preview.configuration.userContentController;
        [controller removeScriptMessageHandlerForName:kMPMathJaxListenerName];
        [controller removeScriptMessageHandlerForName:kMPPreviewScrollName];
        [controller removeAllUserScripts];
        [self.preview removeFromSuperview];
        self.preview = nil;

        [[NSNotificationCenter defaultCenter] removeObserver:self];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        for (NSString *key in MPEditorPreferencesToObserve())
            [defaults removeObserver:self forKeyPath:key];
        for (NSString *key in MPEditorKeysToObserve())
            [self.editor removeObserver:self forKeyPath:key];
    }

    [super close];
}

+ (BOOL)autosavesInPlace
{
    return YES;
}

+ (NSArray *)writableTypes
{
    return @[@"net.daringfireball.markdown"];
}

- (BOOL)isDocumentEdited
{
    // Prevent save dialog on an unnamed, empty document. The file will still
    // show as modified (because it is), but no save dialog will be presented
    // when the user closes it.
    if (!self.presentedItemURL && !self.editor.string.length)
        return NO;
    return [super isDocumentEdited];
}

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)typeName
             error:(NSError *__autoreleasing *)outError
{
    if (self.preferences.editorEnsuresNewlineAtEndOfFile)
    {
        NSCharacterSet *newline = [NSCharacterSet newlineCharacterSet];
        NSString *text = self.editor.string;
        NSUInteger end = text.length;
        if (end && ![newline characterIsMember:[text characterAtIndex:end - 1]])
        {
            NSRange selection = self.editor.selectedRange;
            [self.editor insertText:@"\n" replacementRange:NSMakeRange(end, 0)];
            self.editor.selectedRange = selection;
        }
    }
    return [super writeToURL:url ofType:typeName error:outError];
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
    return [self.editor.string dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName
               error:(NSError **)outError
{
    NSString *content = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
    if (!content)
        return NO;

    self.loadedString = content;
    [self reloadFromLoadedString];
    return YES;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel
{
    savePanel.extensionHidden = NO;
    if (self.fileURL && self.fileURL.isFileURL)
    {
        NSString *path = self.fileURL.path;

        // Use path of parent directory if this is a file. Otherwise this is it.
        BOOL isDir = NO;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path
                                                           isDirectory:&isDir];
        if (!exists || !isDir)
            path = [path stringByDeletingLastPathComponent];

        savePanel.directoryURL = [NSURL fileURLWithPath:path];
    }
    else
    {
        // Suggest a file name for new documents.
        NSString *fileName = self.presumedFileName;
        if (fileName && ![fileName hasExtension:@"md"])
        {
            fileName = [fileName stringByAppendingPathExtension:@"md"];
            savePanel.nameFieldStringValue = fileName;
        }
    }
    
    // Get supported extensions from plist
    static NSMutableArray *supportedExtensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supportedExtensions = [NSMutableArray array];
        NSDictionary *infoDict = [NSBundle mainBundle].infoDictionary;
        for (NSDictionary *docType in infoDict[@"CFBundleDocumentTypes"])
        {
            NSArray *exts = docType[@"CFBundleTypeExtensions"];
            if (exts.count)
            {
                [supportedExtensions addObjectsFromArray:exts];
            }
        }
    });
    
    savePanel.allowedFileTypes = supportedExtensions;
    savePanel.allowsOtherFileTypes = YES; // Allow all extensions.
    
    return [super prepareSavePanel:savePanel];
}

- (NSPrintInfo *)printInfo
{
    NSPrintInfo *info = [super printInfo];
    if (!info)
        info = [[NSPrintInfo sharedPrintInfo] copy];
    info.horizontalPagination = NSAutoPagination;
    info.verticalPagination = NSAutoPagination;
    info.verticallyCentered = NO;
    info.topMargin = 50.0;
    info.leftMargin = 0.0;
    info.rightMargin = 0.0;
    info.bottomMargin = 50.0;
    return info;
}

- (NSPrintOperation *)printOperationWithSettings:(NSDictionary *)printSettings
                                           error:(NSError *__autoreleasing *)e
{
    NSPrintInfo *info = [self.printInfo copy];
    [info.dictionary addEntriesFromDictionary:printSettings];

    NSPrintOperation *op = [self.preview printOperationWithPrintInfo:info];

    // WKWebView hands back an operation whose view has a zero frame, which
    // prints blank pages. Give it the web view's own size to paginate from.
    op.view.frame = self.preview.bounds;
    return op;
}

- (void)printDocumentWithSettings:(NSDictionary *)printSettings
                   showPrintPanel:(BOOL)showPrintPanel delegate:(id)delegate
                 didPrintSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    self.printing = YES;
    NSInvocation *invocation = nil;
    if (delegate && selector)
    {
        NSMethodSignature *signature =
            [NSMethodSignature methodSignatureForSelector:selector];
        invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = delegate;
        if (contextInfo)
            [invocation setArgument:&contextInfo atIndex:2];
    }
    [super printDocumentWithSettings:printSettings
                      showPrintPanel:showPrintPanel delegate:self
                    didPrintSelector:@selector(document:didPrint:context:)
                         contextInfo:(void *)invocation];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    BOOL result = [super validateUserInterfaceItem:item];
    SEL action = item.action;
    if (action == @selector(toggleToolbar:))
    {
        NSMenuItem *it = ((NSMenuItem *)item);
        it.title = self.toolbarVisible ?
            NSLocalizedString(@"Hide Toolbar",
                              @"Toggle reveal toolbar") :
            NSLocalizedString(@"Show Toolbar",
                              @"Toggle reveal toolbar");
    }
    else if (action == @selector(togglePreviewPane:))
    {
        NSMenuItem *it = ((NSMenuItem *)item);
        it.hidden = (!self.previewVisible && self.previousSplitRatio < 0.0);
        it.title = self.previewVisible ?
            NSLocalizedString(@"Hide Preview Pane",
                              @"Toggle preview pane menu item") :
            NSLocalizedString(@"Restore Preview Pane",
                              @"Toggle preview pane menu item");

    }
    else if (action == @selector(toggleEditorPane:))
    {
        NSMenuItem *it = (NSMenuItem*)item;
        it.title = self.editorVisible ?
        NSLocalizedString(@"Hide Editor Pane",
                          @"Toggle editor pane menu item") :
        NSLocalizedString(@"Restore Editor Pane",
                          @"Toggle editor pane menu item");
    }
    else if ((action == @selector(setLightMode:)
              || action == @selector(setDarkMode:)
              || action == @selector(setSepiaMode:))
             && [(NSObject *)item isKindOfClass:[NSMenuItem class]])
    {
        NSMenuItem *it = (NSMenuItem *)item;
        MPViewMode mode = (action == @selector(setDarkMode:)) ? MPViewModeDark
                        : (action == @selector(setSepiaMode:)) ? MPViewModeSepia
                        : MPViewModeLight;
        it.state = (self.preferences.appViewMode == mode)
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return result;
}


#pragma mark - NSSplitViewDelegate

- (void)splitViewDidResizeSubviews:(NSNotification *)notification
{
    [self redrawDivider];
    self.editor.editable = self.editorVisible;

    // Resizing reflows the preview, so both its visible height and every
    // header offset move. Refresh the cached metrics and re-align, or the
    // preview would sit at a stale position until the next editor scroll.
    __weak MPDocument *weakSelf = self;
    [self requestPreviewMetricsWithCompletion:^{
        MPDocument *self_ = weakSelf;
        if (self_ && self_.preferences.editorSyncScrolling)
            [self_ syncScrollers];
    }];
}


#pragma mark - NSTextViewDelegate

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    if (commandSelector == @selector(insertTab:))
        return ![self textViewShouldInsertTab:textView];
    else if (commandSelector == @selector(insertBacktab:))
        return ![self textViewShouldInsertBacktab:textView];
    else if (commandSelector == @selector(insertNewline:))
        return ![self textViewShouldInsertNewline:textView];
    else if (commandSelector == @selector(deleteBackward:))
        return ![self textViewShouldDeleteBackward:textView];
    else if (commandSelector == @selector(moveToLeftEndOfLine:))
        return ![self textViewShouldMoveToLeftEndOfLine:textView];
    return NO;
}

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range
                                              replacementString:(NSString *)str
{
    // Ignore if this originates from an IM marked text commit event.
    if (NSIntersectionRange(textView.markedRange, range).length)
        return YES;

    if (self.preferences.editorCompleteMatchingCharacters)
    {
        BOOL strikethrough = self.preferences.extensionStrikethough;
        if ([textView completeMatchingCharactersForTextInRange:range
                                                    withString:str
                                          strikethroughEnabled:strikethrough])
            return NO;
    }
    
	// For every change, set the typing attributes
	if (range.location > 0) {
		NSRange prevRange = range;
		prevRange.location -= 1;
		prevRange.length = 1;

		NSDictionary *attr = [[textView attributedString] fontAttributesInRange:prevRange];
		[textView setTypingAttributes:attr];
	}

    return YES;
}

#pragma mark - Fake NSTextViewDelegate

- (BOOL)textViewShouldInsertTab:(NSTextView *)textView
{
    if (textView.selectedRange.length != 0)
    {
        [self indent:nil];
        return NO;
    }
    else if (self.preferences.editorConvertTabs)
    {
        [textView insertSpacesForTab];
        return NO;
    }
    return YES;
}

- (BOOL)textViewShouldInsertBacktab:(NSTextView *)textView
{
    [self unindent:nil];
    return NO;
}

- (BOOL)textViewShouldInsertNewline:(NSTextView *)textView
{
    if ([textView insertMappedContent])
        return NO;

    BOOL inserts = self.preferences.editorInsertPrefixInBlock;
    if (inserts && [textView completeNextListItem:
            self.preferences.editorAutoIncrementNumberedLists])
        return NO;
    if (inserts && [textView completeNextBlockquoteLine])
        return NO;
    if ([textView completeNextIndentedLine])
        return NO;
    return YES;
}

- (BOOL)textViewShouldDeleteBackward:(NSTextView *)textView
{
    NSRange selectedRange = textView.selectedRange;
    if (self.preferences.editorCompleteMatchingCharacters)
    {
        NSUInteger location = selectedRange.location;
        if ([textView deleteMatchingCharactersAround:location])
            return NO;
    }
    if (self.preferences.editorConvertTabs && !selectedRange.length)
    {
        NSUInteger location = selectedRange.location;
        if ([textView unindentForSpacesBefore:location])
            return NO;
    }
    return YES;
}

- (BOOL)textViewShouldMoveToLeftEndOfLine:(NSTextView *)textView
{
    if (!self.preferences.editorSmartHome)
        return YES;
    NSUInteger cur = textView.selectedRange.location;
    NSUInteger location =
        [textView.string locationOfFirstNonWhitespaceCharacterInLineBefore:cur];
    if (location == cur || cur == 0)
        return YES;
    else if (cur >= textView.string.length)
        cur = textView.string.length - 1;

    // We don't want to jump rows when the line is wrapped. (#103)
    // If the line is wrapped, the target will be higher than the current glyph.
    NSLayoutManager *manager = textView.layoutManager;
    NSTextContainer *container = textView.textContainer;
    NSRect targetRect =
        [manager boundingRectForGlyphRange:NSMakeRange(location, 1)
                           inTextContainer:container];
    NSRect currentRect =
        [manager boundingRectForGlyphRange:NSMakeRange(cur, 1)
                           inTextContainer:container];
    if (targetRect.origin.y != currentRect.origin.y)
        return YES;

    textView.selectedRange = NSMakeRange(location, 0);
    return NO;
}


#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if ([message.name isEqualToString:kMPPreviewScrollName])
    {
        // Remember where the user left the preview, so the position can be
        // restored after a re-render when scroll syncing is off. This is
        // deliberately one-way: it must never drive the editor, or the two
        // panes would chase each other.
        self.lastPreviewScrollTop = [message.body doubleValue];
        return;
    }

    if ([message.name isEqualToString:kMPMathJaxListenerName]
        && [message.body isEqual:@"End"])
    {
        MPGetPreviewLoadingCompletionHandler(self)();
    }
}


#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    // A superseded load still reports back; ignore anything that is not the
    // navigation we are currently waiting on.
    if (navigation != self.currentNavigation)
        return;

    if (self.preferences.htmlMathJax)
    {
        // MathJax signals completion itself, through the "End" startup hook
        // in init.js. Arm a timeout so a missing CDN cannot leave the preview
        // permanently un-zoomed and un-synced.
        __weak MPDocument *weakSelf = self;
        WKNavigation *thisNavigation = navigation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kMPMathJaxCompletionTimeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MPDocument *strongSelf = weakSelf;
            if (strongSelf && strongSelf.currentNavigation == thisNavigation)
                MPGetPreviewLoadingCompletionHandler(strongSelf)();
        });
    }
    else
    {
        [[NSOperationQueue mainQueue]
            addOperationWithBlock:MPGetPreviewLoadingCompletionHandler(self)];
    }

    self.isPreviewReady = YES;

    // Update word count
    if (self.preferences.editorShowWordCount)
        [self updateWordCount];

    self.alreadyRenderingInWeb = NO;

    if (self.renderToWebPending)
        [self.renderer parseAndRenderNow];

    self.renderToWebPending = NO;
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [self previewNavigation:navigation didFailWithError:error];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error
{
    [self previewNavigation:navigation didFailWithError:error];
}

- (void)previewNavigation:(WKNavigation *)navigation
         didFailWithError:(NSError *)error
{
    if (navigation != self.currentNavigation)
        return;

    // A load cancelled because a newer render replaced it is routine.
    if ([error.domain isEqualToString:NSURLErrorDomain]
        && error.code == NSURLErrorCancelled)
        return;

    [self webView:self.preview didFinishNavigation:navigation];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    // The content process can be jettisoned under memory pressure. Without
    // this the render-in-flight flags stay set and the preview never updates
    // again.
    self.alreadyRenderingInWeb = NO;
    self.renderToWebPending = NO;
    self.currentNavigation = nil;
    [self.renderer parseAndRenderNow];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    // The page lives under the preview scheme, so in-document links come
    // back in it too. Everything below reasons about file URLs.
    NSURL *url = [MPPreviewSchemeHandler
                     fileURLForPreviewURL:navigationAction.request.URL];

    if (navigationAction.navigationType == WKNavigationTypeLinkActivated)
    {
        // If the target is exactly as the current one, ignore.
        if ([self.currentBaseUrl isEqual:url])
        {
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
        }
        // If this is a different page, intercept and handle ourselves.
        else if (![self isCurrentBaseUrl:url])
        {
            decisionHandler(WKNavigationActionPolicyCancel);
            [self openOrCreateFileForUrl:url];
            return;
        }
        // Otherwise this is somewhere else on the same page. Jump there.
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    // Anything else trying to move the main frame off the rendered document
    // is not something the user asked for -- a dropped file, say. The legacy
    // WebView blocked drops through a UIDelegate method that WKWebView has no
    // equivalent for, so refuse the navigation here as well as refusing the
    // drag in MPPreviewWebView.
    if (navigationAction.targetFrame.isMainFrame
        && url && ![self isCurrentBaseUrl:url])
    {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}


#pragma mark - WKUIDelegate

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures
{
    // Links that ask for a new window (target="_blank") go through the same
    // open-or-create path as any other external link.
    NSURL *url = [MPPreviewSchemeHandler
                     fileURLForPreviewURL:navigationAction.request.URL];
    if (url)
        [self openOrCreateFileForUrl:url];
    return nil;
}


#pragma mark - MPRendererDataSource

- (BOOL)rendererLoading {
	return self.preview.loading;
}
    
- (NSString *)rendererMarkdown:(MPRenderer *)renderer
{
    return self.editor.string;
}

- (NSString *)rendererHTMLTitle:(MPRenderer *)renderer
{
    NSString *n = self.fileURL.lastPathComponent.stringByDeletingPathExtension;
    return n ? n : @"";
}


#pragma mark - MPRendererDelegate

- (int)rendererExtensions:(MPRenderer *)renderer
{
    return self.preferences.extensionFlags;
}

- (BOOL)rendererHasSmartyPants:(MPRenderer *)renderer
{
    return self.preferences.extensionSmartyPants;
}

- (BOOL)rendererRendersTOC:(MPRenderer *)renderer
{
    return self.preferences.htmlRendersTOC;
}

- (NSString *)rendererStyleName:(MPRenderer *)renderer
{
    return self.preferences.htmlStyleName;
}

- (BOOL)rendererDetectsFrontMatter:(MPRenderer *)renderer
{
    return self.preferences.htmlDetectFrontMatter;
}

- (BOOL)rendererHasSyntaxHighlighting:(MPRenderer *)renderer
{
    return self.preferences.htmlSyntaxHighlighting;
}

- (BOOL)rendererHasMermaid:(MPRenderer *)renderer
{
    return self.preferences.htmlMermaid;
}

- (BOOL)rendererHasGraphviz:(MPRenderer *)renderer
{
    return self.preferences.htmlGraphviz;
}

- (MPCodeBlockAccessoryType)rendererCodeBlockAccesory:(MPRenderer *)renderer
{
    return self.preferences.htmlCodeBlockAccessory;
}

- (BOOL)rendererHasMathJax:(MPRenderer *)renderer
{
    return self.preferences.htmlMathJax;
}

- (NSString *)rendererHighlightingThemeName:(MPRenderer *)renderer
{
    return self.preferences.htmlHighlightingThemeName;
}

- (void)renderer:(MPRenderer *)renderer didProduceHTMLOutput:(NSString *)html
{
    if (self.alreadyRenderingInWeb)
    {
        self.renderToWebPending = YES;
        return;
    }
    
    if (self.printing)
        return;
    
    self.alreadyRenderingInWeb = YES;

    // Delayed copying for -copyHtml.
    if (self.copying)
    {
        self.copying = NO;
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard writeObjects:@[self.renderer.currentHtml]];
    }

    NSURL *baseUrl = self.fileURL;
    if (!baseUrl)   // Unsaved doument; just use the default URL.
        baseUrl = self.preferences.htmlDefaultDirectoryUrl;

    self.manualRender = self.preferences.markdownManualRender;

    // Set the base URL before kicking off the load: the navigation policy
    // callback consults it, and can fire before -loadHTMLString: returns.
    // currentBaseUrl stays a plain file URL -- everything comparing against
    // it deals in file URLs -- while the page is loaded under the preview
    // scheme so relative subresources reach the scheme handler.
    self.currentBaseUrl = baseUrl;
    self.previewCompletionHandled = NO;

    NSURL *loadBaseUrl = [MPPreviewSchemeHandler previewURLForFileURL:baseUrl];
    self.currentNavigation = [self.preview loadHTMLString:html
                                                  baseURL:loadBaseUrl];
}


#pragma mark - Notification handler

- (void)editorTextDidChange:(NSNotification *)notification
{
    if (self.needsHtml)
        [self.renderer parseAndRenderLater];
}

- (void)userDefaultsDidChange:(NSNotification *)notification
{
    MPRenderer *renderer = self.renderer;

    // Force update if we're switching from manual to auto, or renderer settings
    // changed.
    int rendererFlags = self.preferences.rendererFlags;
    if ((!self.preferences.markdownManualRender && self.manualRender)
            || renderer.rendererFlags != rendererFlags)
    {
        renderer.rendererFlags = rendererFlags;
        [renderer parseAndRenderLater];
    }
    else
    {
        [renderer parseIfPreferencesChanged];
        [renderer renderIfPreferencesChanged];
    }
}

- (void)editorFrameDidChange:(NSNotification *)notification
{
    if (self.preferences.editorWidthLimited)
        [self adjustEditorInsets];
}

- (void)willStartLiveScroll:(NSNotification *)notification
{
    [self updateHeaderLocations];
    _inLiveScroll = YES;
}

-(void)didEndLiveScroll:(NSNotification *)notification
{
    _inLiveScroll = NO;
}

- (void)editorBoundsDidChange:(NSNotification *)notification
{
    if (!self.shouldHandleBoundsChange)
        return;

    if (self.preferences.editorSyncScrolling)
    {
        @synchronized(self) {
            self.shouldHandleBoundsChange = NO;
            if(!_inLiveScroll){
                [self updateHeaderLocations];
            }
            
            [self syncScrollers];
            self.shouldHandleBoundsChange = YES;
        }
    }
}

- (void)didRequestEditorReload:(NSNotification *)notification
{
    NSString *key =
        notification.userInfo[MPDidRequestEditorSetupNotificationKeyName];
    [self setupEditor:key];
}

- (void)didRequestPreviewReload:(NSNotification *)notification
{
    [self render:nil];
}

// The preview's scroll position now arrives through the "previewScroll"
// script message; see -userContentController:didReceiveScriptMessage:.


#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context
{
    if (object == self.editor)
    {
        if (!self.highlighter.isActive)
            return;
        id value = change[NSKeyValueChangeNewKey];
        NSString *preferenceKey = MPEditorPreferenceKeyWithValueKey(keyPath);
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:value forKey:preferenceKey];
    }
    else if (object == [NSUserDefaults standardUserDefaults])
    {
        if (self.highlighter.isActive)
            [self setupEditor:keyPath];
        [self redrawDivider];
    }
}


#pragma mark - IBAction

- (IBAction)copyHtml:(id)sender
{
    // Dis-select things in the preview so that it's more obvious we're NOT
    // respecting the selection range.
    [self.preview evaluateJavaScript:@"window.getSelection().removeAllRanges();"
                   completionHandler:nil];

    // If the preview is hidden, the HTML are not updating on text change.
    // Perform one extra rendering so that the HTML is up to date, and do the
    // copy in the rendering callback.
    if (!self.needsHtml)
    {
        self.copying = YES;
        [self.renderer parseAndRenderNow];
        return;
    }
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[self.renderer.currentHtml]];
}

- (IBAction)exportHtml:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"html"];
    if (self.presumedFileName)
        panel.nameFieldStringValue = self.presumedFileName;

    MPExportPanelAccessoryViewController *controller =
        [[MPExportPanelAccessoryViewController alloc] init];
    controller.stylesIncluded = (BOOL)self.preferences.htmlStyleName;
    controller.highlightingIncluded = self.preferences.htmlSyntaxHighlighting;
    panel.accessoryView = controller.view;

    NSWindow *w = self.windowForSheet;
    [panel beginSheetModalForWindow:w completionHandler:^(NSInteger result) {
        if (result != NSFileHandlingPanelOKButton)
            return;
        BOOL styles = controller.stylesIncluded;
        BOOL highlighting = controller.highlightingIncluded;
        NSString *html = [self.renderer HTMLForExportWithStyles:styles
                                                   highlighting:highlighting];
        [html writeToURL:panel.URL atomically:NO encoding:NSUTF8StringEncoding
                   error:NULL];
    }];
}

- (IBAction)exportPdf:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"pdf"];
    if (self.presumedFileName)
        panel.nameFieldStringValue = self.presumedFileName;
    
    NSWindow *w = nil;
    NSArray *windowControllers = self.windowControllers;
    if (windowControllers.count > 0)
        w = [windowControllers[0] window];

    [panel beginSheetModalForWindow:w completionHandler:^(NSInteger result) {
        if (result != NSFileHandlingPanelOKButton)
            return;

        NSDictionary *settings = @{
            NSPrintJobDisposition: NSPrintSaveJob,
            NSPrintJobSavingURL: panel.URL,
        };
        [self printDocumentWithSettings:settings showPrintPanel:NO delegate:nil
                       didPrintSelector:NULL contextInfo:NULL];
    }];
}

- (IBAction)convertToH1:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:1];
}

- (IBAction)convertToH2:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:2];
}

- (IBAction)convertToH3:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:3];
}

- (IBAction)convertToH4:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:4];
}

- (IBAction)convertToH5:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:5];
}

- (IBAction)convertToH6:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:6];
}

- (IBAction)convertToParagraph:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:0];
}

- (IBAction)toggleStrong:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"**" suffix:@"**"];
}

- (IBAction)toggleEmphasis:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"*" suffix:@"*"];
}

- (IBAction)toggleInlineCode:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"`" suffix:@"`"];
}

- (IBAction)toggleStrikethrough:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"~~" suffix:@"~~"];
}

- (IBAction)toggleUnderline:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"_" suffix:@"_"];
}

- (IBAction)toggleHighlight:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"==" suffix:@"=="];
}

- (IBAction)toggleComment:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"<!--" suffix:@"-->"];
}

- (IBAction)toggleLink:(id)sender
{
    BOOL inserted = [self.editor toggleForMarkupPrefix:@"[" suffix:@"]()"];
    if (!inserted)
        return;

    NSRange selectedRange = self.editor.selectedRange;
    NSUInteger location = selectedRange.location + selectedRange.length + 2;
    selectedRange = NSMakeRange(location, 0);

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *url = [pb URLForType:NSPasteboardTypeString].absoluteString;
    if (url)
    {
        [self.editor insertText:url replacementRange:selectedRange];
        selectedRange.length = url.length;
    }
    self.editor.selectedRange = selectedRange;
}

- (IBAction)toggleImage:(id)sender
{
    BOOL inserted = [self.editor toggleForMarkupPrefix:@"![" suffix:@"]()"];
    if (!inserted)
        return;

    NSRange selectedRange = self.editor.selectedRange;
    NSUInteger location = selectedRange.location + selectedRange.length + 2;
    selectedRange = NSMakeRange(location, 0);

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *url = [pb URLForType:NSPasteboardTypeString].absoluteString;
    if (url)
    {
        [self.editor insertText:url replacementRange:selectedRange];
        selectedRange.length = url.length;
    }
    self.editor.selectedRange = selectedRange;
}

- (IBAction)toggleOrderedList:(id)sender
{
    [self.editor toggleBlockWithPattern:@"^[0-9]+ \\S" prefix:@"1. "];
}

- (IBAction)toggleUnorderedList:(id)sender
{
    NSString *marker = self.preferences.editorUnorderedListMarker;
    [self.editor toggleBlockWithPattern:@"^[\\*\\+-] \\S" prefix:marker];
}

- (IBAction)toggleBlockquote:(id)sender
{
    [self.editor toggleBlockWithPattern:@"^> \\S" prefix:@"> "];
}

- (IBAction)indent:(id)sender
{
    NSString *padding = @"\t";
    if (self.preferences.editorConvertTabs)
        padding = @"    ";
    [self.editor indentSelectedLinesWithPadding:padding];
}

- (IBAction)unindent:(id)sender
{
    [self.editor unindentSelectedLines];
}

- (IBAction)insertNewParagraph:(id)sender
{
    NSRange range = self.editor.selectedRange;
    NSUInteger location = range.location;
    NSUInteger length = range.length;
    NSString *content = self.editor.string;
    NSInteger newlineBefore = [content locationOfFirstNewlineBefore:location];
    NSUInteger newlineAfter =
        [content locationOfFirstNewlineAfter:location + length - 1];

    // If we are on an empty line, treat as normal return key; otherwise insert
    // two newlines.
    if (location == newlineBefore + 1 && location == newlineAfter)
        [self.editor insertNewline:self];
    else
        [self.editor insertText:@"\n\n"];
}

- (IBAction)setEditorOneQuarter:(id)sender
{
    [self setSplitViewDividerLocation:0.25];
}

- (IBAction)setEditorThreeQuarters:(id)sender
{
    [self setSplitViewDividerLocation:0.75];
}

- (IBAction)setEqualSplit:(id)sender
{
    [self setSplitViewDividerLocation:0.5];
}

#pragma mark - Font zoom

- (IBAction)makeFontLarger:(id)sender
{
    [self changeEditorFontSizeBy:1.0];
}

- (IBAction)makeFontSmaller:(id)sender
{
    [self changeEditorFontSizeBy:-1.0];
}

- (IBAction)resetFontSize:(id)sender
{
    NSFont *font = [self.preferences.editorBaseFont copy];
    if (!font)
        return;
    self.preferences.editorBaseFont =
        [NSFont fontWithName:font.fontName size:kMPEditorFontPointSizeDefault];
}

// Nudges the stored base font size. Its setter writes editorBaseFontInfo,
// which is KVO-observed and flows through setupEditor: -> scaleWebview to
// update both the editor font and the preview zoom.
//
// scaleWebview only scales the preview when previewZoomRelativeToBaseFontSize
// is on, so an explicit zoom enables it first — this makes ⌘⌃+/− behave like
// a browser zoom (both panes) and persists across re-renders, since the
// preview-load handler re-applies scaleWebview. Set the pref before the font
// so the resulting scaleWebview already sees it enabled.
- (void)changeEditorFontSizeBy:(CGFloat)delta
{
    NSFont *font = [self.preferences.editorBaseFont copy];
    if (!font)
        return;
    CGFloat size = MIN(MAX(font.pointSize + delta, kMPEditorFontPointSizeMin),
                       kMPEditorFontPointSizeMax);
    self.preferences.previewZoomRelativeToBaseFontSize = YES;
    self.preferences.editorBaseFont = [NSFont fontWithName:font.fontName
                                                      size:size];
}

#pragma mark - View modes (Light / Dark / Sepia)

- (IBAction)setLightMode:(id)sender
{
    [self applyViewMode:MPViewModeLight];
}

- (IBAction)setDarkMode:(id)sender
{
    [self applyViewMode:MPViewModeDark];
}

- (IBAction)setSepiaMode:(id)sender
{
    [self applyViewMode:MPViewModeSepia];
}

// Swaps the editor theme (editorStyleName, KVO -> setupEditor:) and preview
// CSS (htmlStyleName, picked up by userDefaultsDidChange: -> the renderer),
// then matches the window chrome via NSAppearance.
- (void)applyViewMode:(MPViewMode)mode
{
    self.preferences.appViewMode = mode;
    switch (mode)
    {
        case MPViewModeDark:
            self.preferences.editorStyleName = @"Mou Night";
            self.preferences.htmlStyleName = @"Clearness Dark";
            break;
        case MPViewModeSepia:
            self.preferences.editorStyleName = @"Sepia";
            self.preferences.htmlStyleName = @"Sepia";
            break;
        case MPViewModeLight:
        default:
            self.preferences.editorStyleName = @"Tomorrow+";   // current default
            self.preferences.htmlStyleName = @"GitHub2";       // current default
            break;
    }
    [self applyWindowAppearanceForViewMode:mode];
}

- (void)applyWindowAppearanceForViewMode:(MPViewMode)mode
{
    if (@available(macOS 10.14, *))
    {
        NSWindow *window = self.windowControllers.firstObject.window;
        NSString *name = (mode == MPViewModeDark) ? NSAppearanceNameDarkAqua
                                                   : NSAppearanceNameAqua;
        window.appearance = [NSAppearance appearanceNamed:name];
    }
}

- (IBAction)toggleToolbar:(id)sender
{
    [self.windowForSheet toggleToolbarShown:sender];
}

- (IBAction)togglePreviewPane:(id)sender
{
    [self toggleSplitterCollapsingEditorPane:NO];
}

- (IBAction)toggleEditorPane:(id)sender
{
    [self toggleSplitterCollapsingEditorPane:YES];
}

- (IBAction)render:(id)sender
{
    [self.renderer parseAndRenderLater];
}


#pragma mark - Private

- (void)toggleSplitterCollapsingEditorPane:(BOOL)forEditorPane
{
    BOOL isVisible = forEditorPane ? self.editorVisible : self.previewVisible;
    BOOL editorOnRight = self.preferences.editorOnRight;

    float targetRatio = ((forEditorPane == editorOnRight) ? 1.0 : 0.0);

    if (isVisible)
    {
        CGFloat oldRatio = self.splitView.dividerLocation;
        if (oldRatio != 0.0 && oldRatio != 1.0)
        {
            // We don't want to save these values, since they are meaningless.
            // The user should be able to switch between 100% editor and 100%
            // preview without losing the old ratio.
            self.previousSplitRatio = oldRatio;
        }
        [self setSplitViewDividerLocation:targetRatio];
    }
    else
    {
        // We have an inconsistency here, let's just go back to 0.5,
        // otherwise nothing will happen
        if (self.previousSplitRatio < 0.0)
            self.previousSplitRatio = 0.5;

        [self setSplitViewDividerLocation:self.previousSplitRatio];
    }
}

- (void)setupEditor:(NSString *)changedKey
{
    [self.highlighter deactivate];

    if (!changedKey || [changedKey isEqualToString:@"extensionFootnotes"])
    {
        int extensions = pmh_EXT_NOTES;
        if (self.preferences.extensionFootnotes)
            extensions = pmh_EXT_NONE;
        self.highlighter.extensions = extensions;
    }

    if (!changedKey || [changedKey isEqualToString:@"editorHorizontalInset"]
            || [changedKey isEqualToString:@"editorVerticalInset"]
            || [changedKey isEqualToString:@"editorWidthLimited"]
            || [changedKey isEqualToString:@"editorMaximumWidth"])
    {
        [self adjustEditorInsets];
    }

    if (!changedKey || [changedKey isEqualToString:@"editorBaseFontInfo"]
            || [changedKey isEqualToString:@"editorStyleName"]
            || [changedKey isEqualToString:@"editorLineSpacing"])
    {
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.lineSpacing = self.preferences.editorLineSpacing;
        self.editor.defaultParagraphStyle = [style copy];
        NSFont *font = [self.preferences.editorBaseFont copy];
        if (font)
            self.editor.font = font;
        self.editor.textColor = nil;
        self.editor.backgroundColor = [NSColor clearColor];
        self.highlighter.styles = nil;
        [self.highlighter readClearTextStylesFromTextView];

        NSString *themeName = [self.preferences.editorStyleName copy];
        if (themeName.length)
        {
            NSString *path = MPThemePathForName(themeName);
            NSString *themeString = MPReadFileOfPath(path);
            [self.highlighter applyStylesFromStylesheet:themeString
                                       withErrorHandler:
                ^(NSArray *errorMessages) {
                    self.preferences.editorStyleName = nil;
                }];
        }

        CALayer *layer = [CALayer layer];
        CGColorRef backgroundCGColor = self.editor.backgroundColor.CGColor;
        if (backgroundCGColor)
            layer.backgroundColor = backgroundCGColor;
        self.editorContainer.layer = layer;
    }
    
    if ([changedKey isEqualToString:@"editorBaseFontInfo"])
    {
        [self scaleWebview];
    }

    if (!changedKey || [changedKey isEqualToString:@"editorShowWordCount"])
    {
        if (self.preferences.editorShowWordCount)
        {
            self.wordCountWidget.hidden = NO;
            self.editorPaddingBottom.constant = 35.0;
            [self updateWordCount];
        }
        else
        {
            self.wordCountWidget.hidden = YES;
            self.editorPaddingBottom.constant = 0.0;
        }
    }

    if (!changedKey || [changedKey isEqualToString:@"editorScrollsPastEnd"])
    {
        self.editor.scrollsPastEnd = self.preferences.editorScrollsPastEnd;
        NSRect contentRect = self.editor.contentRect;
        NSSize minSize = self.editor.enclosingScrollView.contentSize;
        if (contentRect.size.height < minSize.height)
            contentRect.size.height = minSize.height;
        if (contentRect.size.width < minSize.width)
            contentRect.size.width = minSize.width;
        self.editor.frame = contentRect;
    }

    if (!changedKey)
    {
        NSClipView *contentView = self.editor.enclosingScrollView.contentView;
        contentView.postsBoundsChangedNotifications = YES;

        NSDictionary *keysAndDefaults = MPEditorKeysToObserve();
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        for (NSString *key in keysAndDefaults)
        {
            NSString *preferenceKey = MPEditorPreferenceKeyWithValueKey(key);
            id value = [defaults objectForKey:preferenceKey];
            value = value ? value : keysAndDefaults[key];
            [self.editor setValue:value forKey:key];
        }
    }

    if (!changedKey || [changedKey isEqualToString:@"editorOnRight"])
    {
        BOOL editorOnRight = self.preferences.editorOnRight;
        NSArray *subviews = self.splitView.subviews;
        if ((!editorOnRight && subviews[0] == self.preview)
            || (editorOnRight && subviews[1] == self.preview))
        {
            [self.splitView swapViews];
            if (!self.previewVisible && self.previousSplitRatio >= 0.0)
                self.previousSplitRatio = 1.0 - self.previousSplitRatio;

            // Need to queue this or the views won't be initialised correctly.
            // Don't really know why, but this works.
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                self.splitView.needsLayout = YES;
            }];
        }
    }

    [self.highlighter activate];
    self.editor.automaticLinkDetectionEnabled = NO;
}

- (void)adjustEditorInsets
{
    CGFloat x = self.preferences.editorHorizontalInset;
    CGFloat y = self.preferences.editorVerticalInset;
    if (self.preferences.editorWidthLimited)
    {
        CGFloat editorWidth = self.editor.frame.size.width;
        CGFloat maxWidth = self.preferences.editorMaximumWidth;
        if (editorWidth > 2 * x + maxWidth)
            x = (editorWidth - maxWidth) * 0.45;
        // We tend to expect things in an editor to shift to left a bit.
        // Hence the 0.45 instead of 0.5 (which whould feel a bit too much).
    }
    self.editor.textContainerInset = NSMakeSize(x, y);
}

- (void)redrawDivider
{
    if (!self.editorVisible)
    {
        // If the editor is not visible, match the preview's background.
        // This is read from the page whenever preview metrics are refreshed
        // and cached, because -redrawDivider is called while dragging the
        // divider and cannot afford a round trip into the web content
        // process. It is nil until the first load finishes, which draws the
        // default divider -- the same thing the old DOM query did when it
        // ran before the body existed.
        self.splitView.dividerColor = self.previewBackgroundColor;
    }
    else if (!self.previewVisible)
    {
        // If the editor is visible, match its background color.
        self.splitView.dividerColor = self.editor.backgroundColor;
    }
    else
    {
        // If both sides are visible, draw a default "transparent" divider.
        // This works around the possibile problem of divider's color being too
        // similar to both the editor and preview and being obscured.
        self.splitView.dividerColor = nil;
    }
}

- (void)scaleWebview
{
    if (!self.preferences.previewZoomRelativeToBaseFontSize)
        return;

    CGFloat fontSize = self.preferences.editorBaseFontSize;
    if (fontSize <= 0.0)
        return;

    static const CGFloat defaultSize = 14.0;
    CGFloat scale = fontSize / defaultSize;

    // This used to call -setPageSizeMultiplier:, private WebKit API that the
    // project declared by hand. WKWebView exposes the same thing publicly.
    self.preview.pageZoom = scale;
}

/**
 * Pull the preview's layout metrics out of the page.
 *
 * The legacy WebView let all of this be read synchronously -- header offsets
 * off the DOM, content and visible height off the enclosing scroll view.
 * WKWebView runs the page in another process, so it has to come back through
 * an async JS call and be cached for the scroll-sync maths to use.
 *
 * Requests are coalesced: while one is in flight, further requests just set a
 * dirty flag and one more request is issued when it returns. Scroll and
 * resize can both ask for this many times per second.
 */
- (void)requestPreviewMetricsWithCompletion:(void (^)(void))completion
{
    if (!self.preview)
        return;

    if (self.previewMetricsInFlight)
    {
        self.previewMetricsDirty = YES;
        return;
    }
    self.previewMetricsInFlight = YES;

    __weak MPDocument *weakSelf = self;
    [self.preview evaluateJavaScript:@"window.__mp && window.__mp.metrics()"
                   completionHandler:^(id result, NSError *error) {
        MPDocument *self_ = weakSelf;
        if (!self_)
            return;

        self_.previewMetricsInFlight = NO;

        if ([result isKindOfClass:[NSDictionary class]])
        {
            NSDictionary *metrics = result;

            NSArray *headers = metrics[@"headers"];
            if ([headers isKindOfClass:[NSArray class]])
                self_->_webViewHeaderLocations = [headers copy];

            self_.previewContentHeight = [metrics[@"contentHeight"] doubleValue];
            self_.previewVisibleHeight = [metrics[@"visibleHeight"] doubleValue];

            NSString *background = metrics[@"background"];
            if ([background isKindOfClass:[NSString class]])
            {
                NSColor *color = [NSColor colorWithHTMLName:background];
                if (color)
                {
                    self_.previewBackgroundColor = color;
                    [self_ redrawDivider];
                    if (@available(macOS 12.0, *))
                        self_.preview.underPageBackgroundColor = color;
                }
            }
        }

        if (completion)
            completion();

        if (self_.previewMetricsDirty)
        {
            self_.previewMetricsDirty = NO;
            [self_ requestPreviewMetricsWithCompletion:nil];
        }
    }];
}

/**
 * Scroll the preview, at most once per run-loop pass.
 *
 * Editor bounds changes arrive far faster than the web content process can
 * usefully be driven, and each evaluateJavaScript: is an IPC round trip.
 * Coalescing keeps one scroll per pass with the latest target.
 */
- (void)schedulePreviewScrollFlush
{
    if (self.previewScrollFlushScheduled)
        return;
    self.previewScrollFlushScheduled = YES;

    __weak MPDocument *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MPDocument *self_ = weakSelf;
        if (!self_)
            return;
        self_.previewScrollFlushScheduled = NO;
        if (!self_.preview)
            return;

        NSString *js = [NSString stringWithFormat:
                        @"window.__mp && window.__mp.scrollTo(%f)",
                        self_.pendingPreviewScrollY];
        [self_.preview evaluateJavaScript:js completionHandler:nil];
    });
}

- (void)previewDidFinishLoadingForScrollSync
{
    __weak MPDocument *weakSelf = self;
    [self requestPreviewMetricsWithCompletion:^{
        MPDocument *self_ = weakSelf;
        if (!self_)
            return;

        if (self_.preferences.editorSyncScrolling)
        {
            [self_ updateHeaderLocations];
            [self_ syncScrollers];
        }
        else
        {
            // Put the preview back where the user had scrolled it before the
            // re-render.
            self_.pendingPreviewScrollY = self_.lastPreviewScrollTop;
            [self_ schedulePreviewScrollFlush];
        }
    }];
}

-(void) updateHeaderLocations
{
    // The preview's header offsets are refreshed asynchronously; the cached
    // values from the last round trip are used until it returns.
    [self requestPreviewMetricsWithCompletion:nil];

    NSMutableArray<NSNumber *> *locations = [NSMutableArray array];

    // Next, cache the locations of all of the reference nodes in the editor view.
    NSInteger characterCount = 0;
    NSLayoutManager *layoutManager = [self.editor layoutManager];
    NSArray<NSString *> *documentLines = [self.editor.string componentsSeparatedByString:@"\n"];
    [locations removeAllObjects];

    // These are the patterns for markdown headers and images respectively. we're only going to
    // handle images that are not inline with other text/images
    NSRegularExpression *dashRegex = [NSRegularExpression regularExpressionWithPattern:@"^([-]+)$" options:0 error:nil];
    NSRegularExpression *headerRegex = [NSRegularExpression regularExpressionWithPattern:@"^(#+)\\s" options:0 error:nil];
    NSRegularExpression *imgRegex = [NSRegularExpression regularExpressionWithPattern:@"^!\\[[^\\]]*\\]\\([^)]*\\)$" options:0 error:nil];
    BOOL previousLineHadContent = NO;
    
    CGFloat editorContentHeight = ceilf(NSHeight(self.editor.enclosingScrollView.documentView.bounds));
    CGFloat editorVisibleHeight = ceilf(NSHeight(self.editor.enclosingScrollView.contentView.bounds));

    // We start by splitting our document into lines, and then searching
    // line by line for headers or images.
    for (NSInteger lineNumber = 0; lineNumber < [documentLines count]; lineNumber++)
    {
        NSString *line = documentLines[lineNumber];
        
        if ((previousLineHadContent && [dashRegex numberOfMatchesInString:line options:0 range:NSMakeRange(0, [line length])]) ||
            [imgRegex numberOfMatchesInString:line options:0 range:NSMakeRange(0, [line length])] ||
            [headerRegex numberOfMatchesInString:line options:0 range:NSMakeRange(0, [line length])])
        {
            // Calculate where this header/image appears vertically in the editor
            NSRange glyphRange = [layoutManager glyphRangeForCharacterRange:NSMakeRange(characterCount, [line length]) actualCharacterRange:nil];
            NSRect topRect = [layoutManager boundingRectForGlyphRange:glyphRange inTextContainer:[self.editor textContainer]];
            CGFloat headerY = NSMidY(topRect);

            if(headerY <= editorContentHeight - editorVisibleHeight){
                [locations addObject:@(headerY)];
            }
        }
        
        previousLineHadContent = [line length] && ![dashRegex numberOfMatchesInString:line options:0 range:NSMakeRange(0, [line length])];
        
        characterCount += [line length] + 1;
    }

    _editorHeaderLocations = [locations copy];
}

- (void)syncScrollers
{
    CGFloat editorContentHeight = ceilf(NSHeight(self.editor.enclosingScrollView.documentView.bounds));
    CGFloat editorVisibleHeight = ceilf(NSHeight(self.editor.enclosingScrollView.contentView.bounds));

    // Preview geometry comes from the last metrics round trip rather than a
    // scroll view, because a WKWebView has neither a document view nor an
    // enclosing scroll view to measure.
    CGFloat previewContentHeight = ceilf(self.previewContentHeight);
    CGFloat previewVisibleHeight = ceilf(self.previewVisibleHeight);

    // Nothing measured yet -- the first metrics callback will sync us.
    if (previewVisibleHeight <= 0.0)
        return;

    NSInteger relativeHeaderIndex = -1; // -1 is start of document, before any other header
    CGFloat currY = NSMinY(self.editor.enclosingScrollView.contentView.bounds);
    CGFloat minY = 0;
    CGFloat maxY = 0;
    
    // align the documents at the middle of the screen, except at top/bottom of document
    CGFloat topTaper = MAX(0, MIN(1.0, currY / editorVisibleHeight));
    CGFloat bottomTaper = 1.0 - MAX(0, MIN(1.0, (currY - editorContentHeight + 2 * editorVisibleHeight) / editorVisibleHeight));
    CGFloat adjustmentForScroll = topTaper * bottomTaper * editorVisibleHeight / 2;

    // We start by splitting our document into lines, and then searching
    // line by line for headers or images.
    for (NSNumber *headerYNum in _editorHeaderLocations) {
        CGFloat headerY = [headerYNum floatValue];
        headerY -= adjustmentForScroll;
        
        if (headerY < currY)
        {
            // The header is before our current scroll position. the closest
            // of these will be our first reference node
            relativeHeaderIndex += 1;
            minY = headerY;
        } else if (maxY == 0 && headerY < editorContentHeight - editorVisibleHeight)
        {
            // Skip any headers that are within the last screen of the editor.
            // we'll interpolate to the end of the document in that case.
            maxY = headerY;
        }
    }
    
    // Usually, we'll be scrolling between two reference nodes, but toward the end
    // of the document we'll ignore nodes and reference the end of the document instead
    BOOL interpolateToEndOfDocument = NO;
    
    if (maxY == 0)
    {
        // We only have a reference node before our current position,
        // but not after, so we'll use the end of the document.
        maxY = editorContentHeight - editorVisibleHeight + adjustmentForScroll;
        interpolateToEndOfDocument = YES;
    }

    // We are currently at currY offset, between minY and maxY, which represent
    // headers indexed by relativeHeaderIndex and relativeHeaderIndex+1.
    currY = MAX(0, currY - minY);
    maxY -= minY;
    minY -= minY;
    CGFloat percentScrolledBetweenHeaders = MAX(0, MIN(1.0, currY / maxY));
    
    // Now that we know where the editor position is relative to two reference nodes,
    // we need to find the positions of those nodes in the HTML preview
    CGFloat topHeaderY = 0;
    CGFloat bottomHeaderY = previewContentHeight - previewVisibleHeight;
    
    // Find the Y positions in the preview window that we're scrolling between
    if ([_webViewHeaderLocations count] > relativeHeaderIndex)
    {
        topHeaderY = floorf([_webViewHeaderLocations[relativeHeaderIndex] doubleValue]) - adjustmentForScroll;
    }
    
    if (!interpolateToEndOfDocument && [_webViewHeaderLocations count] > relativeHeaderIndex + 1)
    {
        bottomHeaderY = ceilf([_webViewHeaderLocations[relativeHeaderIndex + 1] doubleValue]) - adjustmentForScroll;
    }
    
    // Now we scroll percentScrolledBetweenHeaders percent between those two positions in the webview
    CGFloat previewY = topHeaderY + (bottomHeaderY - topHeaderY) * percentScrolledBetweenHeaders;
#ifdef MP_DEBUG_SCROLL_SYNC
    NSLog(@"[sync] editorY=%.1f eContent=%.1f eVisible=%.1f | pContent=%.1f "
          @"pVisible=%.1f | idx=%ld pct=%.3f top=%.1f bottom=%.1f -> previewY=%.1f "
          @"| editorHeaders=%lu webHeaders=%lu",
          NSMinY(self.editor.enclosingScrollView.contentView.bounds),
          editorContentHeight, editorVisibleHeight,
          previewContentHeight, previewVisibleHeight,
          (long)relativeHeaderIndex, percentScrolledBetweenHeaders,
          topHeaderY, bottomHeaderY, previewY,
          (unsigned long)_editorHeaderLocations.count,
          (unsigned long)_webViewHeaderLocations.count);
#endif
    self.pendingPreviewScrollY = previewY;
    [self schedulePreviewScrollFlush];
}

- (void)setSplitViewDividerLocation:(CGFloat)ratio
{
    BOOL wasVisible = self.previewVisible;
    [self.splitView setDividerLocation:ratio];
    if (!wasVisible && self.previewVisible
            && !self.preferences.markdownManualRender)
        [self.renderer parseAndRenderNow];
    [self setupEditor:NSStringFromSelector(@selector(editorHorizontalInset))];
}

- (NSString *)presumedFileName
{
    if (self.fileURL)
        return self.fileURL.lastPathComponent.stringByDeletingPathExtension;

    NSString *title = nil;
    NSString *string = self.editor.string;
    if (self.preferences.htmlDetectFrontMatter)
        title = [[[string frontMatter:NULL] objectForKey:@"title"] description];
    if (title)
        return title;

    title = string.titleString;
    if (!title)
        return NSLocalizedString(@"Untitled", @"default filename if no title can be determined");

    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"[/|:]"
                                                          options:0 error:NULL];
    });

    NSRange range = NSMakeRange(0, title.length);
    title = [regex stringByReplacingMatchesInString:title options:0 range:range
                                       withTemplate:@"-"];
    return title;
}

- (void)updateWordCount
{
    __weak MPDocument *weakSelf = self;
    [self.preview evaluateJavaScript:@"window.__mp && window.__mp.textForCount()"
                   completionHandler:^(id result, NSError *error) {
        MPDocument *self_ = weakSelf;
        if (!self_ || ![result isKindOfClass:[NSDictionary class]])
            return;

        NSString *words = result[@"words"];
        NSString *chars = result[@"chars"];
        if (![words isKindOfClass:[NSString class]]
            || ![chars isKindOfClass:[NSString class]])
            return;

        self_.totalWords = words.numberOfWords;
        self_.totalCharacters = chars.lengthWithoutNewlines;
        self_.totalCharactersNoSpaces = chars.lengthWithoutWhitespacesAndNewlines;
#ifdef MP_DEBUG_WORD_COUNT
        NSLog(@"[wc] words=%lu chars=%lu charsNoSpaces=%lu",
              (unsigned long)self_.totalWords,
              (unsigned long)self_.totalCharacters,
              (unsigned long)self_.totalCharactersNoSpaces);
#endif

        if (self_.isPreviewReady)
            self_.wordCountWidget.enabled = YES;
    }];
}

- (BOOL)isCurrentBaseUrl:(NSURL *)another
{
    NSString *mine = self.currentBaseUrl.absoluteBaseURLString;
    NSString *theirs = another.absoluteBaseURLString;
    return mine == theirs || [mine isEqualToString:theirs];
}


#define OPEN_FAIL_ALERT_INFORMATIVE NSLocalizedString( \
@"Please check the path of your link is correct. Turn on \
“Automatically create link targets” If you want MacDown to \
create nonexistent link targets for you.", \
@"preview navigation error information")

#define AUTO_CREATE_FAIL_ALERT_INFORMATIVE NSLocalizedString( \
@"MacDown can’t create a file for the clicked link because \
the current file is not saved anywhere yet. Save the \
current file somewhere to enable this feature.", \
@"preview navigation error information")


- (void)openOrCreateFileForUrl:(NSURL *)url
{
    // Simply open the file if it is not local, or exists already.
    BOOL file = url.isFileURL;
    BOOL reachable = !file || [url checkResourceIsReachableAndReturnError:NULL];
    
    // If the file is local but doesn't exist, check if a file with
    // the .md extension exists.
    if (file && !reachable && [url.pathExtension isEqualToString:@""])
    {
        NSURL *markdownURL = [url URLByAppendingPathExtension:@"md"];
        if ([markdownURL checkResourceIsReachableAndReturnError:NULL])
        {
            reachable = YES;
            url = markdownURL;
        }
    }
    
    if (reachable)
    {
        [[NSWorkspace sharedWorkspace] openURL:url];
        return;
    }

    // Show an error if the user doesn't want us to create it automatically.
    if (!self.preferences.createFileForLinkTarget)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        NSString *template = NSLocalizedString(
            @"File not found at path:\n%@",
            @"preview navigation error message");
        alert.messageText = [NSString stringWithFormat:template, url.path];
        alert.informativeText = OPEN_FAIL_ALERT_INFORMATIVE;
        [alert runModal];
        return;
    }

    // We can only create a file if the current file is saved. (Why?)
    if (!self.fileURL)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        NSString *template = NSLocalizedString(
            @"Can’t create file:\n%@", @"preview navigation error message");
        alert.messageText = [NSString stringWithFormat:template,
                             url.lastPathComponent];
        alert.informativeText = AUTO_CREATE_FAIL_ALERT_INFORMATIVE;
        [alert runModal];
    }

    // Try to created the file.
    NSDocumentController *controller =
        [NSDocumentController sharedDocumentController];

    NSError *error = nil;
    id doc = [controller createNewEmptyDocumentForURL:url
                                              display:YES error:&error];
    if (!doc)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        NSString *template = NSLocalizedString(
            @"Can’t create file:\n%@",
            @"preview navigation error message");
        alert.messageText =
            [NSString stringWithFormat:template, url.lastPathComponent];
        template = NSLocalizedString(
            @"An error occurred while creating the file:\n%@",
            @"preview navigation error information");
        alert.informativeText =
            [NSString stringWithFormat:template, error.localizedDescription];
        [alert runModal];
    }
}


- (void)document:(NSDocument *)doc didPrint:(BOOL)ok context:(void *)context
{
    if ([doc respondsToSelector:@selector(setPrinting:)])
        ((MPDocument *)doc).printing = NO;
    if (context)
    {
        NSInvocation *invocation = (__bridge NSInvocation *)context;
        if ([invocation isKindOfClass:[NSInvocation class]])
        {
            [invocation setArgument:&doc atIndex:0];
            [invocation setArgument:&ok atIndex:1];
            [invocation invoke];
        }
    }
}

@end
