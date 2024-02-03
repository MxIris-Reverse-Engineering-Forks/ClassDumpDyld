//
//  ClassDumpDyldHelper.h
//  ClassDumpDyld
//
//  Created by JH on 2024/1/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ClassDumpDyldHelper : NSObject

@property (nonatomic, assign, class, readonly) BOOL isArch64;

+ (BOOL)isMachOExecutable:(const char *)image;
+ (BOOL)is64BitMachO:(const char *)image;
+ (BOOL)fileExistsOnDisk:(const char *)image;
+ (long)locationOfString:(const char *)haystack needle:(const char *)needle;
+ (BOOL)hasMalformedIDWithParts:(NSString *)parts;

@end

BOOL isMachOExecutable(const char *image);
BOOL is64BitMachO(const char *image);
BOOL fileExistsOnDisk(const char *image);
BOOL arch64(void);
long locationOfString(const char *haystack, const char *needle);
NSString * print_free_memory(void);
NSString * copyrightMessage(char *image);
void loadBar(int x, int n, int r, int w, const char *className);
NS_ASSUME_NONNULL_END
