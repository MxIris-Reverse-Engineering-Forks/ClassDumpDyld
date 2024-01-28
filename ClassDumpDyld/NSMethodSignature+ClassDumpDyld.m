//
//  NSMethodSignature+ClassDumpDyld.m
//  ClassDumpDyld
//
//  Created by JH on 2024/1/26.
//

#import "NSMethodSignature+ClassDumpDyld.h"

@implementation NSMethodSignature (ClassDumpDyld)
+ (NSMethodSignature *)cd_signatureWithObjCTypes:(const char *)types {
    __block NSString *text = [NSString stringWithCString:types encoding:NSUTF8StringEncoding];

    while ([text rangeOfString:@"("].location != NSNotFound) {
        NSRegularExpressionOptions opt = 0;
        NSRegularExpression *regex =
            [NSRegularExpression regularExpressionWithPattern:@"\\(([^\\(\\)]+)\\)"
                                                      options:opt
                                                        error:nil];

        // test if the anticipated union (embraced in parentheseis) is actually a function definition
        // rather than a union

        NSRange range = [text rangeOfString:@"\\(([^\\(\\)]+)\\)" options:NSRegularExpressionSearch];
        NSString *rep = [text substringWithRange:range];
        NSString *testUnion =
            [rep stringByReplacingOccurrencesOfString:@"("
                                           withString:@"{"]; // just to test if it internally passes as
        // a masqueraded struct
        testUnion = [testUnion stringByReplacingOccurrencesOfString:@")" withString:@"}"];

        if ([testUnion rangeOfString:@"="].location == NSNotFound) {
            // its a function!
            text = [text stringByReplacingOccurrencesOfString:@"(" withString:@"__FUNCTION_START__"];
            text = [text stringByReplacingOccurrencesOfString:@")" withString:@"__FUNCTION_END__"];
            continue;
        }

        [regex
         enumerateMatchesInString:text
                          options:0
                            range:NSMakeRange(0, [text length])
                       usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags,
                                    BOOL *stop) {
            for (int i = 1; i < [result numberOfRanges]; i++) {
                NSString *textFound = [text substringWithRange:[result rangeAtIndex:i]];
                text = [text
                        stringByReplacingOccurrencesOfString:[NSString
                                                              stringWithFormat:@"(%@)",
                                                              textFound]
                                                  withString:
                        [NSString
                         stringWithFormat:
                         @"{union={%@}ficificifloc}",
                         textFound]];      // add an
                // impossible match
                // of types
                *stop = YES;
            }
        }];
    }

    if ([text rangeOfString:@"{"].location != NSNotFound) {
        BOOL FOUND = 1;
        NSRegularExpressionOptions opt = 0;
        NSRegularExpression *regex =
            [NSRegularExpression regularExpressionWithPattern:@"(?<!\\^)\\{([^\\{^\\}]+)\\}"
                                                      options:opt
                                                        error:nil];

        while (FOUND) {
            NSRange range = [regex rangeOfFirstMatchInString:text
                                                     options:0
                                                       range:NSMakeRange(0, [text length])];

            if (range.location != NSNotFound) {
                FOUND = 1;
                NSString *result = [text substringWithRange:range];
                text = [text
                        stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@", result]
                                                  withString:[NSString stringWithFormat:@"^^^%@", result]];
            } else {
                FOUND = 0;
            }
        }

        FOUND = 1;
        regex = [NSRegularExpression regularExpressionWithPattern:@"(?<!\\^)\\{([^\\}]+)\\}"
                                                          options:opt
                                                            error:nil];

        while (FOUND) {
            NSRange range = [regex rangeOfFirstMatchInString:text
                                                     options:0
                                                       range:NSMakeRange(0, [text length])];

            if (range.location != NSNotFound) {
                FOUND = 1;
                NSString *result = [text substringWithRange:range];
                text = [text
                        stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@", result]
                                                  withString:[NSString stringWithFormat:@"^^^%@", result]];
            } else {
                FOUND = 0;
            }
        }
    }

    text = [text stringByReplacingOccurrencesOfString:@"__FUNCTION_START__" withString:@"("];
    text = [text stringByReplacingOccurrencesOfString:@"__FUNCTION_END__" withString:@")"];

    types = [text UTF8String];

    @try {
        return [self signatureWithObjCTypes:types];
    } @catch (NSException *exception) {
        return nil;
    } @finally {}
}

- (const char *)cd_getArgumentTypeAtIndex:(NSUInteger)anIndex {
    const char *argument = [self getArgumentTypeAtIndex:anIndex];

    NSString *char_ns = [NSString stringWithCString:argument encoding:NSUTF8StringEncoding];
    __block NSString *text = char_ns;

    if ([text rangeOfString:@"^^^"].location != NSNotFound) {
        text = [text stringByReplacingOccurrencesOfString:@"^^^" withString:@""];
    }

    while ([text rangeOfString:@"{union"].location != NSNotFound) {
        NSRegularExpressionOptions opt = 0;
        NSRegularExpression *regex =
            [NSRegularExpression regularExpressionWithPattern:@"(\\{union.+?ficificifloc\\})"
                                                      options:opt
                                                        error:nil];
        [regex
         enumerateMatchesInString:text
                          options:0
                            range:NSMakeRange(0, [text length])
                       usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags,
                                    BOOL *stop) {
            for (int i = 1; i < [result numberOfRanges]; i++) {
                NSString *textFound = [text substringWithRange:[result rangeAtIndex:i]];

                NSString *textToPut = [textFound substringFromIndex:8];
                textToPut = [textToPut
                             substringToIndex:textToPut.length - 1 - (@"ficificifloc".length + 1)];
                text = [text
                        stringByReplacingOccurrencesOfString:[NSString
                                                              stringWithFormat:@"%@",
                                                              textFound]
                                                  withString:[NSString
                                    stringWithFormat:@"(%@)",
                                                              textToPut]];
                *stop = YES;
            }
        }];
    }

    char_ns = text;
    return [char_ns UTF8String];
}
@end
