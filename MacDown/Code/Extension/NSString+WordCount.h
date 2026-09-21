//
//  NSString+WordCount.h
//  MacDown
//
//  Extracted from DOMNode+Text.h when the preview moved to WKWebView; the
//  DOM walk that used to feed these now happens in JavaScript, but the
//  counting rules are unchanged.
//

#import <Foundation/Foundation.h>

@interface NSString (WordCount)

@property (readonly, nonatomic) NSUInteger numberOfWords;
@property (readonly, nonatomic) NSUInteger lengthWithoutNewlines;
@property (readonly, nonatomic) NSUInteger lengthWithoutWhitespacesAndNewlines;

@end
