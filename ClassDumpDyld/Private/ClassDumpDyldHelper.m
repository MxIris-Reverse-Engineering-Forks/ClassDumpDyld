//
//  ClassDumpDyldHelper.m
//  ClassDumpDyld
//
//  Created by JH on 2024/1/26.
//

#import "ClassDumpDyldHelper.h"
#import <mach-o/dyld.h>
@implementation ClassDumpDyldHelper

+ (BOOL)isMachOExecutable:(const char *)image {
    FILE *machoFile = fopen(image, "rb");

    if (machoFile == 0) {
        return NO;
    }

    //#ifdef __LP64__
    struct mach_header_64 machHeader;
    //#else
    // mach_header machHeader;
    //#endif

    unsigned long n = fread(&machHeader, sizeof(machHeader), 1, machoFile);

    if (n != 1) {
        fclose(machoFile);
        return NO;
    }

    BOOL isExec = machHeader.filetype == MH_EXECUTE;

    fclose(machoFile);
    return isExec;
}

+ (BOOL)is64BitMachO:(const char *)image {
    FILE *machoFile = fopen(image, "rb");

    if (machoFile == 0) {
        fclose(machoFile);
        return NO;
    }

    struct mach_header_64 machHeader;
    unsigned long n = fread(&machHeader, sizeof(machHeader), 1, machoFile);

    if (n != 1) {
        fclose(machoFile);
        return NO;
    }

    BOOL is64 = machHeader.magic != MH_MAGIC;  // instead of ==MH_MAGIC_64
    fclose(machoFile);
    return is64;
}

+ (BOOL)fileExistsOnDisk:(const char *)image {
    FILE *aFile = fopen(image, "r");
    BOOL exists = aFile != 0;

    fclose(aFile);
    return exists;
}

+ (BOOL)isArch64 {
#ifdef __LP64__
    return YES;

#endif
    return NO;
}

+ (long)locationOfString:(const char *)haystack needle:(const char *)needle {
    const char *found = strstr(haystack, needle);
    long anIndex = -1;

    if (found != NULL) {
        anIndex = found - haystack;
    }

    return anIndex;
}

+ (BOOL)hasMalformedIDWithParts:(NSString *)parts {
    if ([parts rangeOfString:@"@\""].location != NSNotFound &&
        [parts rangeOfString:@"@\""].location + 2 < parts.length - 1 &&
        ([[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2] rangeOfString:@"\""]
         .location == [[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2]
                       rangeOfString:@"\"\""]
         .location ||
         [[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2] rangeOfString:@"\""]
         .location == [[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2]
                       rangeOfString:@"\"]"]
         .location ||
         [[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2] rangeOfString:@"\""]
         .location ==
         [parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2].length - 1)) {
        return YES;
    }

    return NO;
}

@end


long locationOfString(const char *haystack, const char *needle) {
    const char *found = strstr(haystack, needle);
    long anIndex = -1;

    if (found != NULL) {
        anIndex = found - haystack;
    }

    return anIndex;
}

BOOL isMachOExecutable(const char *image) {
    FILE *machoFile = fopen(image, "rb");

    if (machoFile == 0) {
        return NO;
    }

    //#ifdef __LP64__
    struct mach_header_64 machHeader;
    //#else
    // mach_header machHeader;
    //#endif

    unsigned long n = fread(&machHeader, sizeof(machHeader), 1, machoFile);

    if (n != 1) {
        fclose(machoFile);
        return NO;
    }

    BOOL isExec = machHeader.filetype == MH_EXECUTE;

    fclose(machoFile);
    return isExec;
}

BOOL is64BitMachO(const char *image) {
    FILE *machoFile = fopen(image, "rb");

    if (machoFile == 0) {
        fclose(machoFile);
        return NO;
    }

    struct mach_header_64 machHeader;
    unsigned long n = fread(&machHeader, sizeof(machHeader), 1, machoFile);

    if (n != 1) {
        fclose(machoFile);
        return NO;
    }

    BOOL is64 = machHeader.magic != MH_MAGIC;  // instead of ==MH_MAGIC_64
    fclose(machoFile);
    return is64;
}

BOOL fileExistsOnDisk(const char *image) {
    FILE *aFile = fopen(image, "r");
    BOOL exists = aFile != 0;

    fclose(aFile);
    return exists;
}

BOOL arch64(void) {
    // size_t size;
    // sysctlbyname("hw.cpu64bit_capable", NULL, &size, NULL, 0);
    // BOOL cpu64bit;
    // sysctlbyname("hw.cpu64bit_capable", &cpu64bit, &size, NULL, 0);
    // return cpu64bit;

#ifdef __LP64__
    return YES;

#endif
    return NO;
}
