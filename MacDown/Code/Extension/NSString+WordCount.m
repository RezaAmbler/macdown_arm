//
//  NSString+WordCount.m
//  MacDown
//

#import "NSString+WordCount.h"

@implementation NSString (WordCount)

- (NSUInteger)numberOfWords
{
    __block NSUInteger count = 0;
    NSStringEnumerationOptions options =
    NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired;
    [self enumerateSubstringsInRange:NSMakeRange(0, self.length)
                             options:options usingBlock:
     ^(NSString *str, NSRange strRange, NSRange enclosingRange, BOOL *stop) {
         count++;
     }];
    return count;
}

- (NSUInteger)lengthWithoutNewlines
{
    static NSCharacterSet *sp = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sp = [NSCharacterSet newlineCharacterSet];
    });

    NSUInteger length = 0;
    for (NSString *comp in [self componentsSeparatedByCharactersInSet:sp])
        length += comp.length;
    return length;
}


- (NSUInteger)lengthWithoutWhitespacesAndNewlines
{
    static NSCharacterSet *sp = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sp = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    });

    NSUInteger length = 0;
    for (NSString *comp in [self componentsSeparatedByCharactersInSet:sp])
        length += comp.length;
    return length;
}

@end
