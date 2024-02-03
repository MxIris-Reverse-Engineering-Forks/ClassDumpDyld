//
//  NSMethodSignature+ClassDumpDyld.h
//  ClassDumpDyld
//
//  Created by JH on 2024/1/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSMethodSignature (ClassDumpDyld)
+ (nullable NSMethodSignature *)cd_signatureWithObjCTypes:(const char *)types;
- (const char *)cd_getArgumentTypeAtIndex:(NSUInteger)anIndex;
@end

NS_ASSUME_NONNULL_END
