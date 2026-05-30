//
//  MPHeadingAnchorTests.m
//  MacDown
//
//  Tests for GitHub-style heading anchor slugs and id injection used to make
//  in-document table-of-contents links resolve.
//

#import <XCTest/XCTest.h>
#import "MPRenderer.h"


@interface MPHeadingAnchorTests : XCTestCase
@end


@implementation MPHeadingAnchorTests

#pragma mark - Slug generation

- (void)testSlugMatchesGitHubForNumberedHeadings
{
    XCTAssertEqualObjects([MPRenderer anchorSlugForHeadingText:@"1. Product Overview"],
                          @"1-product-overview");
    XCTAssertEqualObjects([MPRenderer anchorSlugForHeadingText:@"3. Tech Stack"],
                          @"3-tech-stack");
    XCTAssertEqualObjects([MPRenderer anchorSlugForHeadingText:@"12. Testing Standards"],
                          @"12-testing-standards");
}

- (void)testSlugPreservesExistingHyphen
{
    XCTAssertEqualObjects([MPRenderer anchorSlugForHeadingText:@"5. Multi-Tenancy"],
                          @"5-multi-tenancy");
}

- (void)testSlugDropsAmpersandLeavingDoubleHyphen
{
    XCTAssertEqualObjects(
        [MPRenderer anchorSlugForHeadingText:@"6. Authentication & Authorization"],
        @"6-authentication--authorization");
    XCTAssertEqualObjects(
        [MPRenderer anchorSlugForHeadingText:@"17. Code Style & Conventions"],
        @"17-code-style--conventions");
}

- (void)testSlugDropsParentheses
{
    XCTAssertEqualObjects(
        [MPRenderer anchorSlugForHeadingText:@"10. Device Integration (Adapters)"],
        @"10-device-integration-adapters");
}

- (void)testSlugLowercasesAndDropsPunctuation
{
    XCTAssertEqualObjects([MPRenderer anchorSlugForHeadingText:@"Hello, World!"],
                          @"hello-world");
    XCTAssertEqualObjects([MPRenderer anchorSlugForHeadingText:@"CONFIG.yml & .env"],
                          @"configyml--env");
}

#pragma mark - Anchor injection

- (void)testAddsAnchorInsideHeading
{
    NSString *html = @"<h2>1. Product Overview</h2>";
    XCTAssertEqualObjects([MPRenderer HTMLByAddingHeadingAnchors:html],
        @"<h2><a class=\"md-heading-anchor\" id=\"1-product-overview\">"
        @"</a>1. Product Overview</h2>");
}

- (void)testHandlesAllLevels
{
    NSString *html = @"<h1>Top</h1><h6>Deep Section</h6>";
    NSString *out = [MPRenderer HTMLByAddingHeadingAnchors:html];
    XCTAssertTrue([out containsString:@"id=\"top\""]);
    XCTAssertTrue([out containsString:@"id=\"deep-section\""]);
}

- (void)testStripsInlineMarkupWhenSlugging
{
    NSString *html = @"<h2>Some <strong>Bold</strong> Title</h2>";
    NSString *out = [MPRenderer HTMLByAddingHeadingAnchors:html];
    XCTAssertTrue([out containsString:@"id=\"some-bold-title\""]);
    // Inner markup is preserved in the output.
    XCTAssertTrue([out containsString:@"<strong>Bold</strong>"]);
}

- (void)testDecodesAmpersandEntity
{
    NSString *html = @"<h2>Authentication &amp; Authorization</h2>";
    NSString *out = [MPRenderer HTMLByAddingHeadingAnchors:html];
    XCTAssertTrue([out containsString:@"id=\"authentication--authorization\""]);
}

- (void)testDeduplicatesRepeatedHeadings
{
    NSString *html = @"<h2>Notes</h2><h2>Notes</h2><h2>Notes</h2>";
    NSString *out = [MPRenderer HTMLByAddingHeadingAnchors:html];
    XCTAssertTrue([out containsString:@"id=\"notes\""]);
    XCTAssertTrue([out containsString:@"id=\"notes-1\""]);
    XCTAssertTrue([out containsString:@"id=\"notes-2\""]);
}

- (void)testPreservesExistingHeadingId
{
    // hoedown emits id="toc_N"; we must keep it (the [TOC] feature links to it)
    // while still adding the slug anchor.
    NSString *html = @"<h2 id=\"toc_0\">Title</h2>";
    NSString *out = [MPRenderer HTMLByAddingHeadingAnchors:html];
    XCTAssertTrue([out containsString:@"id=\"toc_0\""]);   // original kept
    XCTAssertTrue([out containsString:@"id=\"title\""]);   // slug anchor added
}

- (void)testLeavesNonHeadingContentUntouched
{
    NSString *html = @"<p>A paragraph with <a href=\"#x\">a link</a>.</p>";
    XCTAssertEqualObjects([MPRenderer HTMLByAddingHeadingAnchors:html], html);
}

- (void)testHandlesEmptyAndNil
{
    XCTAssertEqualObjects([MPRenderer HTMLByAddingHeadingAnchors:@""], @"");
}

@end


#pragma mark - End-to-end render pipeline

// Minimal stub so MPRenderer can run parseMarkdown: without a document.
@interface MPAnchorStubDelegate : NSObject <MPRendererDataSource, MPRendererDelegate>
@property (copy) NSString *markdown;
@end

@implementation MPAnchorStubDelegate
- (BOOL)rendererLoading { return NO; }
- (NSString *)rendererMarkdown:(MPRenderer *)r { return self.markdown; }
- (NSString *)rendererHTMLTitle:(MPRenderer *)r { return @""; }
- (int)rendererExtensions:(MPRenderer *)r { return 0; }
- (BOOL)rendererHasSmartyPants:(MPRenderer *)r { return NO; }
- (BOOL)rendererRendersTOC:(MPRenderer *)r { return NO; }
- (NSString *)rendererStyleName:(MPRenderer *)r { return nil; }
- (BOOL)rendererDetectsFrontMatter:(MPRenderer *)r { return NO; }
- (BOOL)rendererHasSyntaxHighlighting:(MPRenderer *)r { return NO; }
- (BOOL)rendererHasMermaid:(MPRenderer *)r { return NO; }
- (BOOL)rendererHasGraphviz:(MPRenderer *)r { return NO; }
- (MPCodeBlockAccessoryType)rendererCodeBlockAccesory:(MPRenderer *)r
{ return MPCodeBlockAccessoryNone; }
- (BOOL)rendererHasMathJax:(MPRenderer *)r { return NO; }
@end

@interface MPRenderer (Testing)
- (void)parseMarkdown:(NSString *)markdown;
@end

@interface MPHeadingAnchorPipelineTests : XCTestCase
@end

@implementation MPHeadingAnchorPipelineTests

- (NSString *)renderedBodyFor:(NSString *)markdown
{
    MPRenderer *renderer = [[MPRenderer alloc] init];
    MPAnchorStubDelegate *stub = [[MPAnchorStubDelegate alloc] init];
    stub.markdown = markdown;
    renderer.dataSource = stub;
    renderer.delegate = stub;
    [renderer parseMarkdown:markdown];
    return renderer.currentHtml;
}

- (void)testFullPipelineProducesHeadingAnchors
{
    NSString *body = [self renderedBodyFor:@"## 1. Product Overview\n\nText.\n"];
    XCTAssertTrue([body containsString:@"id=\"1-product-overview\""],
                  @"Rendered body should contain the slug anchor. Got: %@", body);
}

- (void)testFullPipelineMatchesHandWrittenTOCLinks
{
    NSString *md =
        @"## Table of Contents\n\n"
        @"1. [Authentication & Authorization](#6-authentication--authorization)\n"
        @"2. [Device Integration (Adapters)](#10-device-integration-adapters)\n\n"
        @"## 6. Authentication & Authorization\n\nText.\n\n"
        @"## 10. Device Integration (Adapters)\n\nText.\n";
    NSString *body = [self renderedBodyFor:md];
    XCTAssertTrue([body containsString:@"id=\"6-authentication--authorization\""],
                  @"Body: %@", body);
    XCTAssertTrue([body containsString:@"id=\"10-device-integration-adapters\""],
                  @"Body: %@", body);
}

@end
