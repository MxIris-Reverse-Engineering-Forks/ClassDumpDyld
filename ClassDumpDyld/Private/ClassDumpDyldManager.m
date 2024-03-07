//
//  ClassDumpDyldManager.m
//  ClassDumpDyld
//
//  Created by JH on 2024/1/26.
//

#import "ClassDumpDyldManager.h"
#import "ClassDumpDyldHelper.h"
#import "NSMethodSignature+ClassDumpDyld.h"
#import "Singleton.h"
#import "dyld_cache_format.h"
#import <dirent.h>
#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
@implementation NSArray (Safe)

- (nullable id)objectAtSafeIndex:(NSUInteger)safeIndex {
    return safeIndex < self.count ? self[safeIndex] : nil;
}

@end

#define CDLog(...) \
if (self.isDebug) NSLog(@"classdump-dyld : %@", [NSString stringWithFormat:__VA_ARGS__])

typedef void *MSImageRef;

static NSErrorDomain const ClassDumpDyldErrorDomain = @"ClassDumpDyldErrorDomain";

@interface ClassDumpDyldManager () {
    uint8_t *_cacheData;
    struct dyld_cache_header *_cacheHead;
}



@property (nonatomic) BOOL shouldImportStructs;
@property (nonatomic) BOOL shouldDLopen32BitExecutables;
@property (nonatomic, copy, nullable) NSString *classID;
@property (nonatomic, copy, nullable) NSString *onlyOneClass;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *allStructsFound;
@property (nonatomic, strong) NSMutableArray<NSString *> *allImagesProcessed;
@property (nonatomic, strong) NSMutableArray<NSString *> *classesInStructs;
@property (nonatomic, strong) NSMutableArray<NSString *> *classesInClass;
@property (nonatomic, strong) NSMutableArray<NSString *> *processedImages;
@property (nonatomic, strong) NSMutableSet<NSString *> *mutableForbiddenClasses;
@property (nonatomic, strong) NSMutableSet<NSString *> *mutableForbiddenPaths;
@end

@implementation ClassDumpDyldManager

SingletonImplementation(ClassDumpDyldManager, sharedManager)

- (void)addForbiddenClasses:(NSSet<NSString *> *)classes {
    [self.mutableForbiddenClasses unionSet:classes];
}

- (void)addForbiddenPaths:(NSSet<NSString *> *)paths {
    [self.mutableForbiddenPaths unionSet:paths];
}

- (void)clearResources {
    self.allStructsFound = nil;
    self.allImagesProcessed = nil;
    self.classesInStructs = nil;
    self.classesInClass = nil;
    self.processedImages = nil;
}

- (void)allImagesWithCompletion:(void (^)(NSArray<NSString *> * _Nullable, NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
#if TARGET_CPU_ARM64
        const char *filename = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e";
#else
        const char *filename = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64";
#endif
        FILE *fp = fopen(filename, "r");
        fclose(fp);
        // Thanks to DHowett & KennyTM~ for dyld_shared_cache listing codes
        struct stat filebuffer;
        stat(filename, &filebuffer);
        unsigned long long filesize = filebuffer.st_size;
        int fd = open(filename, O_RDONLY);
        _cacheData = (uint8_t *)mmap(NULL, filesize, PROT_READ, MAP_PRIVATE, fd, 0);
        _cacheHead = (struct dyld_cache_header *)_cacheData;
        uint64_t curoffset = _cacheHead->imagesOffset;
        NSMutableArray<NSString *> *allImages = [NSMutableArray array];
        for (unsigned i = 0; i < _cacheHead->imagesCount; ++i) {
            uint64_t fo = *(uint64_t *)(_cacheData + curoffset + 24);
            curoffset += 32;
            char *imageInCache = (char *)_cacheData + fo;
            
            NSStringCompareOptions opts = 0;
            NSMutableString *imageToNSString =
            [[NSMutableString alloc] initWithCString:imageInCache encoding:NSUTF8StringEncoding];
            [imageToNSString replaceOccurrencesOfString:@"///"
                                             withString:@"/"
                                                options:opts
                                                  range:NSMakeRange(0, [imageToNSString length])];
            [imageToNSString replaceOccurrencesOfString:@"//"
                                             withString:@"/"
                                                options:opts
                                                  range:NSMakeRange(0, [imageToNSString length])];
            
            [allImages addObject:imageToNSString];
        }
        
        munmap(_cacheData, filesize);
        close(fd);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(allImages, nil);
            }
        });
    });
}

- (void)dumpImageHeaders:(NSString *)image toPath:(NSString *)outputPath completion:(void (^ _Nullable)(NSError * _Nullable))completion {
    [self clearResources];
    
    [self parseImage:(char *)[image UTF8String] outputDir:outputPath isRecursive:YES isBuildOriginalDirs:YES isSimpleHeader:NO isSkipAlreadyFound:NO isSkipApplications:YES completion:completion];
}


- (void)parseImage:(char *)image outputDir:(NSString *)outputDir isRecursive:(BOOL)isRecursive isBuildOriginalDirs:(BOOL)buildOriginalDirs isSimpleHeader:(BOOL)simpleHeader isSkipAlreadyFound:(BOOL)skipAlreadyFound isSkipApplications:(BOOL)skipApplications completion:(void (^ _Nullable)(NSError * _Nullable))completion {
    if (!image) {
        completion([NSError errorWithDomain:ClassDumpDyldErrorDomain code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"Image is nil"
        }]);
        return;
    }
    
    NSString *imageAsNSString = [[NSString alloc] initWithCString:image encoding:NSUTF8StringEncoding];
    
    for (NSString *forbiddenPath in self.forbiddenPaths) {
        if ([imageAsNSString rangeOfString:forbiddenPath].location != NSNotFound) {
            
            completion([NSError errorWithDomain:ClassDumpDyldErrorDomain code:5 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Image %@ cannot be parsed due to known crashing issues.", imageAsNSString]
            }]);
            return;
        }
    }
    
    
    // check if image is executable
    dlopen_preflight(image);
    BOOL isExec = NO;
    
    if (dlerror()) {
        if (fileExistsOnDisk(image)) {
            isExec = isMachOExecutable(image);
        }
    }
    
    void *ref = nil;
    BOOL opened = dlopen_preflight(image);
    const char *dlopenError = dlerror();
    
    @autoreleasepool {
        if (opened) {
            CDLog(@"Will dlopen %s", image);
            ref = dlopen(image, RTLD_LAZY);
            CDLog(@"Did dlopen %s", image);
        } else {
            completion([NSError errorWithDomain:ClassDumpDyldErrorDomain code:10 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%s image dlopen failed", image],
            }]);
            return;
        }
    }
    
    
    CDLog(@"Dlopen complete, proceeding with class info for %s", image);
    // PROCEED
    BOOL isFramework = NO;
    NSMutableString *dumpString = [[NSMutableString alloc] initWithString:@""];
    unsigned int count;
    CDLog(@"Getting class count for %s", image);
    const char **names = objc_copyClassNamesForImage(image, &count);
    CDLog(@"Did return class count %d", count);
    
    
    while ([outputDir rangeOfString:@"/" options:NSBackwardsSearch].location == outputDir.length - 1) {
        outputDir = [outputDir substringToIndex:outputDir.length - 1];
    }
    
    self.allStructsFound = nil;
    self.classesInStructs = nil;
    
    NSMutableArray *protocolsAdded = [NSMutableArray array];
    
    NSString *imageName = [[NSString stringWithCString:image encoding:NSUTF8StringEncoding] lastPathComponent];
    NSString *fullImageNameInNS = [NSString stringWithCString:image encoding:NSUTF8StringEncoding];
    [self.allImagesProcessed addObject:fullImageNameInNS];
    
    NSString *seeIfIsBundleType = [fullImageNameInNS stringByDeletingLastPathComponent];
    NSString *lastComponent = [seeIfIsBundleType lastPathComponent];
    NSString *targetDir = nil;
    
    if ([lastComponent rangeOfString:@"."].location == NSNotFound) {
        targetDir = fullImageNameInNS;
    } else {
        targetDir = [fullImageNameInNS stringByDeletingLastPathComponent];
        isFramework = YES;
    }
    
    NSString *headersFolder = self.addHeadersFolder ? @"/Headers" : @"";
    NSString *writeDir = buildOriginalDirs ? (isFramework ? [NSString stringWithFormat:@"%@/%@%@", outputDir, targetDir, headersFolder] : [NSString stringWithFormat:@"%@/%@", outputDir, targetDir]) : outputDir;
    writeDir = [writeDir stringByReplacingOccurrencesOfString:@"///" withString:@"/"];
    writeDir = [writeDir stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
    
    [self.processedImages addObject:[NSString stringWithCString:image encoding:NSUTF8StringEncoding]];
    CDLog(@"Beginning class loop (%d classed) for %s", count, image);
    NSMutableString *classesToImport = [[NSMutableString alloc] init];
    
    int actuallyProcesssedCount = 0;
    
    for (unsigned i = 0; i < count; i++) {
        @autoreleasepool {
            self.classesInClass = nil;
            NSMutableArray *inlineProtocols = [NSMutableArray array];
            self.shouldImportStructs = NO;
            BOOL fileIsExist = [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/%s.h", writeDir, names[i]]];
            if (skipAlreadyFound && fileIsExist) {
                continue;
            }
            
            BOOL canGetSuperclass = YES;
            NSString *classNameNSToRelease = [[NSString alloc] initWithCString:names[i] encoding:NSUTF8StringEncoding];
            
            if ([self.forbiddenClasses containsObject:classNameNSToRelease]) {
                continue;
            }
            
            if ([classNameNSToRelease rangeOfString:@"_INP"].location == 0 || [classNameNSToRelease rangeOfString:@"ASV"].location == 0) {
                continue;
            }
            
            if (self.onlyOneClass && ![classNameNSToRelease isEqual:self.onlyOneClass]) {
                continue;
            }
            
            actuallyProcesssedCount++;
            
            CDLog(@"Processing Class %s (%d/%d)\n", names[i], i, count);
            
            if (!names[i]) {
                printf("\n stringWithCString names[i] empty \n");
            }
            
            NSString *classNameNS = [NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding];
            
            while ([classNameNS rangeOfString:@"_"].location == 0) {
                classNameNS = [classNameNS substringFromIndex:1];
            }
            self.classID = [classNameNS substringToIndex:2];
            Class currentClass = nil;
            
            currentClass = objc_getClass(names[i]);
            
            if (!class_getClassMethod(currentClass, NSSelectorFromString(@"doesNotRecognizeSelector:"))) {
                canGetSuperclass = NO;
            }
            
            if (!class_getClassMethod(currentClass, NSSelectorFromString(@"methodSignatureForSelector:"))) {
                canGetSuperclass = NO;
            }
            
            if (strcmp((char *)image, (char *)"/System/Library/CoreServices/SpringBoard.app/SpringBoard") == 0) {
                [currentClass class];  // init a class instance to prevent crashes, specifically needed for
                // some SpringBoard classes
            }
            
            NSString *superclassString = nil;
            
            if (canGetSuperclass) {
                //                @try {
                Class superclass = class_getSuperclass(currentClass);
                if (superclass) {
                    const char *superclassName = class_getName(superclass);
                    superclassString = [NSString stringWithFormat:@": %s", superclassName];
                } else {
                    superclassString = @"";
                }
                //                    superclassString = [[currentClass superclass] description] != nil ? [NSString stringWithFormat:@" : %@", [[currentClass superclass] description]] : @"";
                //                } @catch (NSException *exception) {
                //                    NSLog(@"Trigger Exception: %@", exception);
                //                    continue;
                //                } @finally {}
            } else {
                superclassString = @" : _UKNOWN_SUPERCLASS_";
            }
            
            
            unsigned int protocolCount;
            Protocol *__unsafe_unretained _Nonnull *_Nullable protocolArray = class_copyProtocolList(currentClass, &protocolCount);
            NSString *inlineProtocolsString = @"";
            
            for (unsigned t = 0; t < protocolCount; t++) {
                if (t == 0) {
                    inlineProtocolsString = @" <";
                }
                
                const char *protocolName = protocol_getName(protocolArray[t]);
                
                if (!protocolName) {
                    printf("\n stringWithCString protocolName empty \n");
                }
                
                NSString *addedProtocol = [NSString stringWithCString:protocolName encoding:NSUTF8StringEncoding];
                
                if (t < protocolCount - 1) {
                    addedProtocol = [addedProtocol stringByAppendingString:@", "];
                }
                
                inlineProtocolsString = [inlineProtocolsString stringByAppendingString:addedProtocol];
                
                if (t == protocolCount - 1) {
                    inlineProtocolsString = [inlineProtocolsString stringByAppendingString:@">"];
                }
            }
            
            if (superclassString.length > 0 && ![superclassString isEqual:@" : NSObject"]) {
                NSString *fixedSuperclass = [superclassString stringByReplacingOccurrencesOfString:@" : " withString:@""];
                NSString *importSuper = @"";
                
                if (!simpleHeader) {
                    NSString *imagePrefix = [imageName substringToIndex:2];
                    
                    NSString *superclassPrefix = [superclassString rangeOfString:@"_"].location == 0 ? [[superclassString substringFromIndex:1] substringToIndex:2] : [superclassString substringToIndex:2];
                    const char *imageNameOfSuper = [imagePrefix isEqual:superclassPrefix] ? [imagePrefix UTF8String] : class_getImageName(objc_getClass([fixedSuperclass UTF8String]));
                    
                    if (imageNameOfSuper) {
                        NSString *imageOfSuper = [NSString stringWithCString:imageNameOfSuper encoding:NSUTF8StringEncoding];
                        imageOfSuper = [imageOfSuper lastPathComponent];
                        importSuper = [NSString stringWithFormat:@"#import <%@/%@.h>\n", imageOfSuper, fixedSuperclass];
                    }
                } else {
                    importSuper = [NSString stringWithFormat:@"#import \"%@.h\"\n", fixedSuperclass];
                }
                
                [dumpString appendString:importSuper];
            }
            
            for (unsigned d = 0; d < protocolCount; d++) {
                Protocol *protocol = protocolArray[d];
                const char *protocolName = protocol_getName(protocol);
                
                if (!protocolName) {
                    printf("\n stringWithCString protocolName empty \n");
                }
                
                NSString *protocolNSString = [NSString stringWithCString:protocolName encoding:NSUTF8StringEncoding];
                
                if (simpleHeader) {
                    [dumpString appendString:[NSString stringWithFormat:@"#import \"%@.h\"\n", protocolNSString]];
                } else {
                    NSString *imagePrefix = [imageName substringToIndex:2];
                    NSString *protocolPrefix = nil;
                    NSString *imageOfProtocol = nil;
                    
                    protocolPrefix = [protocolNSString rangeOfString:@"_"].location == 0 ? [[protocolNSString substringFromIndex:1] substringToIndex:2] : [protocolNSString substringToIndex:2];
                    
                    if (!class_getImageName((Class)protocol)) {
                        printf("\n stringWithCString class_getImageName(protocol) empty \n");
                    }
                    
                    
                    
                    NSString *imageNameForProtocol = nil;
                    const char *imageNameForProtocolCString = class_getImageName((Class)protocol);
                    if (imageNameForProtocolCString) {
                        imageNameForProtocol = [NSString stringWithCString:imageNameForProtocolCString encoding:NSUTF8StringEncoding];
                    }
                    imageOfProtocol = ([imagePrefix isEqual:protocolPrefix] || !imageNameForProtocol || [imageNameForProtocol containsString:@"libobjc.A.dylib"])
                    ? imageName
                    : imageNameForProtocol;
                    imageOfProtocol = [imageOfProtocol lastPathComponent];
                    
                    if ([protocolNSString rangeOfString:@"UI"].location == 0) {
                        imageOfProtocol = @"UIKit";
                    }
                    
                    [dumpString appendString:[NSString stringWithFormat:@"#import <%@/%@.h>\n", imageOfProtocol, protocolNSString]];
                }
                
                
                if ([protocolsAdded containsObject:protocolNSString]) {
                    continue;
                }
                
                [protocolsAdded addObject:protocolNSString];
                NSString *protocolHeader = [self buildProtocolFile:protocol];
                
                if (strcmp(names[i], protocolName) == 0) {
                    [dumpString appendString:protocolHeader];
                } else {
                    
                    [[NSFileManager defaultManager] createDirectoryAtPath:writeDir
                                              withIntermediateDirectories:YES
                                                               attributes:nil
                                                                    error:nil];
                    
                    if (![protocolHeader
                          writeToFile:[NSString stringWithFormat:@"%@/%s.h", writeDir, protocolName]
                          atomically:YES
                          encoding:NSUTF8StringEncoding
                          error:nil]) {
                        printf("  Failed to save protocol header to directory \"%s\"\n", [writeDir UTF8String]);
                    }
                }
            }
            
            free(protocolArray);
            
            [dumpString appendString:[NSString stringWithFormat:@"\n@interface %s%@%@", names[i],
                                      superclassString, inlineProtocolsString]];
            // Get Ivars
            unsigned int ivarOutCount;
            Ivar *ivarArray = class_copyIvarList(currentClass, &ivarOutCount);
            
            if (ivarOutCount > 0) {
                [dumpString appendString:@" {\n"];
                
                for (unsigned x = 0; x < ivarOutCount; x++) {
                    Ivar currentIvar = ivarArray[x];
                    const char *ivarName = ivar_getName(currentIvar);
                    
                    if (!ivarName) {
                        printf("\n stringWithCString ivarName empty \n");
                    }
                    
                    NSString *ivarNameNS = [NSString stringWithCString:ivarName encoding:NSUTF8StringEncoding];
                    const char *ivarType = ivar_getTypeEncoding(currentIvar);
                    
                    if (!ivarType) {
                        printf("\n stringWithCString ivarType empty for ivarName %s in class %s with ivar count "
                               "%u \n",
                               ivarName, [[currentClass description] UTF8String], ivarOutCount);
                    }
                    
                    NSString *ivarTypeString = NULL;
                    
                    if (ivarType) {
                        ivarTypeString = [self commonTyps:[NSString stringWithCString:ivarType encoding:NSUTF8StringEncoding] inName:&ivarNameNS inIvarList:YES];
                        
                        if ([ivarTypeString rangeOfString:@"@\""].location != NSNotFound) {
                            ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@"@\"" withString:@""];
                            ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@"\"" withString:@"*"];
                            NSString *classFoundInIvars = [ivarTypeString stringByReplacingOccurrencesOfString:@"*" withString:@""];
                            
                            if (![self.classesInClass containsObject:classFoundInIvars]) {
                                if ([classFoundInIvars rangeOfString:@"<"].location != NSNotFound) {
                                    NSUInteger firstOpening = [classFoundInIvars rangeOfString:@"<"].location;
                                    
                                    if (firstOpening != 0) {
                                        NSString *classToAdd = [classFoundInIvars substringToIndex:firstOpening];
                                        
                                        if (![self.classesInClass containsObject:classToAdd]) {
                                            [self.classesInClass addObject:classToAdd];
                                        }
                                    }
                                    
                                    NSString *protocolToAdd = [classFoundInIvars substringFromIndex:firstOpening];
                                    protocolToAdd = [protocolToAdd stringByReplacingOccurrencesOfString:@"<" withString:@""];
                                    protocolToAdd = [protocolToAdd stringByReplacingOccurrencesOfString:@">" withString:@""];
                                    protocolToAdd = [protocolToAdd stringByReplacingOccurrencesOfString:@"*" withString:@""];
                                    
                                    if (![inlineProtocols containsObject:protocolToAdd]) {
                                        [inlineProtocols addObject:protocolToAdd];
                                    }
                                } else {
                                    [self.classesInClass addObject:classFoundInIvars];
                                }
                            }
                            
                            if ([ivarTypeString rangeOfString:@"<"].location != NSNotFound) {
                                //                                ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@">*" withString:@">"];
                                
                                if ([ivarTypeString rangeOfString:@"<"].location == 0) {
                                    ivarTypeString = [@"id" stringByAppendingString:ivarTypeString];
                                    ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@">*" withString:@">"];
                                } else {
                                    //                                    ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@"<" withString:@"*<"];
                                }
                            }
                        }
                    } else {
                        ivarTypeString = @"???";
                    }
                    
                    NSString *formatted = [NSString stringWithFormat:@"\n\t%@ %@;", ivarTypeString, ivarNameNS];
                    [dumpString appendString:formatted];
                }
                
                [dumpString appendString:@"\n\n}"];
            }
            
            free(ivarArray);
            
            if ([inlineProtocols count] > 0) {
                NSMutableString *inlineProtocolsString = [[NSMutableString alloc] init];
                [inlineProtocolsString appendString:@"@protocol "];
                
                for (int g = 0; g < inlineProtocols.count; g++) {
                    if (g < inlineProtocols.count - 1) {
                        [inlineProtocolsString
                         appendString:[NSString stringWithFormat:@"%@, ", [inlineProtocols objectAtIndex:g]]];
                    } else {
                        [inlineProtocolsString
                         appendString:[NSString stringWithFormat:@"%@;\n", [inlineProtocols objectAtIndex:g]]];
                    }
                }
                
                NSUInteger interfaceLocation = [dumpString rangeOfString:@"@interface"].location;
                [dumpString insertString:inlineProtocolsString atIndex:interfaceLocation];
            }
            
            // Get Properties
            unsigned int propertiesCount;
            NSString *propertiesString = @"";
            objc_property_t *propertyList = class_copyPropertyList(currentClass, &propertiesCount);
            
            for (unsigned int b = 0; b < propertiesCount; b++) {
                const char *propname = property_getName(propertyList[b]);
                const char *attrs = property_getAttributes(propertyList[b]);
                
                if (!attrs) {
                    printf("\n stringWithCString attrs empty \n");
                }
                
                if (!propname) {
                    printf("\n stringWithCString propname empty \n");
                }
                NSString *attributes = [NSString stringWithCString:attrs encoding:NSUTF8StringEncoding];
                NSString *name = [NSString stringWithCString:propname encoding:NSUTF8StringEncoding];
                NSString *newString = [self buildPropertyWithAttributes:attributes withName:name];
                
                if ([propertiesString rangeOfString:newString].location == NSNotFound) {
                    propertiesString =
                    [propertiesString stringByAppendingString:newString];
                }
            }
            
            free(propertyList);
            
            // Fix synthesize locations
            NSUInteger propLenght = [propertiesString length];
            NSMutableArray *synthesized =
            [[propertiesString componentsSeparatedByString:@"\n"] mutableCopy];
            NSUInteger longestLocation = 0;
            
            for (NSString __strong *string in synthesized) {
                string = [string stringByReplacingOccurrencesOfString:@"\t" withString:@""];
                string = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSUInteger location = [string rangeOfString:@";"].location;
                
                if ([string rangeOfString:@";"].location == NSNotFound) {
                    continue;
                }
                
                if (location > longestLocation) {
                    longestLocation = location;
                }
            }
            
            NSMutableArray *newStrings = [NSMutableArray array];
            
            for (NSString __strong *string in synthesized) {
                NSUInteger synthesizeLocation = [string rangeOfString:@"//@synth"].location;
                
                if ([string rangeOfString:@"//@synth"].location == NSNotFound) {
                    [newStrings addObject:string];
                    continue;
                }
                
                NSString *copyString = [string substringFromIndex:synthesizeLocation];
                NSUInteger location = [string rangeOfString:@";"].location;
                string = [string substringToIndex:location + 1];
                string = [string stringByPaddingToLength:longestLocation + 15
                                              withString:@" "
                                         startingAtIndex:0];
                string = [string stringByAppendingString:copyString];
                [newStrings addObject:string];
            }
            
            if (propLenght > 0) {
                propertiesString =
                [@"\n" stringByAppendingString:[newStrings componentsJoinedByString:@"\n"]];
            }
            
            // Gather All Strings
            [dumpString appendString:propertiesString];
            [dumpString appendString:[self buildMethodsWithClass:object_getClass(currentClass) isInstanceMethod:NO withProperties:nil]];
            [dumpString appendString:[self buildMethodsWithClass:currentClass isInstanceMethod:YES withProperties:[self buildPropertiesWithString:propertiesString]]];
            [dumpString appendString:@"\n@end\n\n"];
            
            if (self.shouldImportStructs) {
                NSUInteger firstImport = [dumpString rangeOfString:@"#import"].location != NSNotFound
                ? [dumpString rangeOfString:@"#import"].location
                : [dumpString rangeOfString:@"@interface"].location;
                NSString *structImport =
                simpleHeader
                ? [NSString stringWithFormat:@"#import \"%@-Structs.h\"\n", imageName]
                : [NSString stringWithFormat:@"#import <%@/%@-Structs.h>\n", imageName, imageName];
                [dumpString insertString:structImport atIndex:firstImport];
            }
            
            if ([self.classesInClass count] > 0) {
                if (!names[i]) {
                    printf("\n stringWithCString names[i] empty \n");
                }
                
                [self.classesInClass removeObject:[NSString stringWithCString:names[i]
                                                                     encoding:NSUTF8StringEncoding]];
                
                if ([self.classesInClass count] > 0) {
                    NSUInteger firstInteface = [dumpString rangeOfString:@"@interface"].location;
                    NSMutableString *classesFoundToAdd = [[NSMutableString alloc] init];
                    [classesFoundToAdd appendString:@"@class "];
                    
                    for (int f = 0; f < self.classesInClass.count; f++) {
                        NSString *classFound = [self.classesInClass objectAtIndex:f];
                        
                        if (f < self.classesInClass.count - 1) {
                            [classesFoundToAdd appendString:[NSString stringWithFormat:@"%@, ", classFound]];
                        } else {
                            [classesFoundToAdd appendString:[NSString stringWithFormat:@"%@;", classFound]];
                        }
                    }
                    
                    [classesFoundToAdd appendString:@"\n\n"];
                    [dumpString insertString:classesFoundToAdd atIndex:firstInteface];
                }
            }
            
            // Write strings to disk or print out
            NSError *writeError;
            
            [[NSFileManager defaultManager] createDirectoryAtPath:writeDir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            NSString *fileToWrite = [NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding];
            
            if ([[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding]
                 isEqual:[[NSString stringWithCString:image
                                             encoding:NSUTF8StringEncoding] lastPathComponent]]) {
                fileToWrite = [[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding]
                               stringByAppendingString:@"-Class"];
            }
            
            if (![dumpString writeToFile:[NSString stringWithFormat:@"%@/%@.h", writeDir, fileToWrite]
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:&writeError]) {
                
                completion([NSError errorWithDomain:ClassDumpDyldErrorDomain code:-1 userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to save to directory \"%s\"", [writeDir UTF8String]]
                }]);
                return;
                
                //                if (writeError != nil) {
                //                    printf("  %s\n", [[writeError description] UTF8String]);
                //                }
                //
                //                break;
            }
            
            NSString *importStringFrmt =
            simpleHeader ? [NSString stringWithFormat:@"#import \"%s.h\"\n", names[i]]
            : [NSString stringWithFormat:@"#import <%@/%s.h>\n", imageName, names[i]];
            [classesToImport appendString:importStringFrmt];
            
            
            dumpString = [[NSMutableString alloc] init];
        }
    }
    
    // END OF PER-CLASS LOOP
    
    if (actuallyProcesssedCount == 0 && self.onlyOneClass) {
        printf("\r\n" "\t\tlibclassdump-dyld:" " Class \"" "%s"
               "\" not found" " in %s\r\n\r\n",
               [self.onlyOneClass UTF8String], image);
    }
    
    if (classesToImport.length > 2) {
        [[NSFileManager defaultManager] createDirectoryAtPath:writeDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        
        if (![classesToImport writeToFile:[NSString stringWithFormat:@"%@/%@.h", writeDir, imageName]
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:nil]) {
            printf("  Failed to save header list to directory \"%s\"\n", [writeDir UTF8String]);
        }
    }
    
    CDLog(@"Finished class loop for %s", image);
    
    // Compose FrameworkName-Structs.h file
    
    @autoreleasepool {
        if ([self.allStructsFound count] > 0) {
            NSString *structsString = @"";
            
            
            NSError *writeError;
            
            if ([self.classesInStructs count] > 0) {
                structsString = [structsString stringByAppendingString:@"\n@class "];
                
                for (NSString *string in self.classesInStructs) {
                    structsString = [structsString
                                     stringByAppendingString:[NSString stringWithFormat:@"%@, ", string]];
                }
                
                structsString =
                [structsString substringToIndex:structsString.length - 2];
                structsString = [structsString stringByAppendingString:@";\n\n"];
            }
            
            for (NSDictionary *dict in self.allStructsFound) {
                structsString = [structsString
                                 stringByAppendingString:[dict objectForKey:@"representation"]];
            }
            
            [[NSFileManager defaultManager] createDirectoryAtPath:writeDir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            
            if (![structsString
                  writeToFile:[NSString stringWithFormat:@"%@/%@-Structs.h", writeDir, imageName]
                  atomically:YES
                  encoding:NSUTF8StringEncoding
                  error:&writeError]) {
                printf("  Failed to save structs to directory \"%s\"\n", [writeDir UTF8String]);
                
                if (writeError != nil) {
                    printf("  %s\n", [[writeError description] UTF8String]);
                }
            }
        }
    }
    
    
    free(names);
    
    completion(nil);
}

- (NSString *)buildPropertyWithAttributes:(NSString *)attributes withName:(NSString *)name {
    NSCharacterSet *parSet = [NSCharacterSet characterSetWithCharactersInString:@"()"];
    
    attributes = [attributes stringByTrimmingCharactersInSet:parSet];
    NSMutableArray *attrArr = (NSMutableArray *)[attributes componentsSeparatedByString:@","];
    NSString *type = [attrArr objectAtIndex:0];
    
    type = [type stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:@""];
    
    if ([type rangeOfString:@"@"].location == 0 &&
        [type rangeOfString:@"\""].location != NSNotFound) {  // E.G. @"NSTimer"
        type = [type stringByReplacingOccurrencesOfString:@"\"" withString:@""];
        type = [type stringByReplacingOccurrencesOfString:@"@" withString:@""];
        type = [type stringByAppendingString:@" *"];
        NSString *classFoundInProperties = [type stringByReplacingOccurrencesOfString:@" *"
                                                                           withString:@""];
        
        if (![self.classesInClass containsObject:classFoundInProperties] &&
            [classFoundInProperties rangeOfString:@"<"].location == NSNotFound) {
            [self.classesInClass addObject:classFoundInProperties];
        }
        
        if ([type rangeOfString:@"<"].location != NSNotFound) {
            //            type = [type stringByReplacingOccurrencesOfString:@"> *" withString:@">"];
            
            if ([type rangeOfString:@"<"].location == 0) {
                type = [@"id" stringByAppendingString:type];
                type = [type stringByReplacingOccurrencesOfString:@"> *" withString:@">"];
            } else {
                //                type = [type stringByReplacingOccurrencesOfString:@"<" withString:@"*<"];
            }
        }
    } else if ([type rangeOfString:@"@"].location == 0 &&
               [type rangeOfString:@"\""].location == NSNotFound) {
        type = @"id";
    } else {
        type = [self commonTyps:type inName:&name inIvarList:NO];
    }
    
    if ([type rangeOfString:@"="].location != NSNotFound) {
        type = [type substringToIndex:[type rangeOfString:@"="].location];
        
        if ([type rangeOfString:@"_"].location == 0) {
            type = [type substringFromIndex:1];
        }
    }
    
    type = [type stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    attrArr = [NSMutableArray arrayWithArray:attrArr];
    [attrArr removeObjectAtIndex:0];
    NSMutableArray *newPropsArray = [NSMutableArray array];
    NSString *synthesize = @"";
    
    for (NSString __strong *attr in attrArr) {
        NSString *vToClear = nil;
        
        if ([attr rangeOfString:@"V_"].location == 0) {
            vToClear = attr;
            attr = [attr stringByReplacingCharactersInRange:NSMakeRange(0, 2) withString:@""];
            synthesize =
            [NSString stringWithFormat:@"\t\t\t\t//@synthesize %@=_%@ - In the implementation block",
             attr, attr];
        }
        
        if ([attr length] == 1) {
            NSString *translatedProperty = attr;
            
            if ([attr isEqual:@"R"]) {
                translatedProperty = @"readonly";
            }
            
            if ([attr isEqual:@"C"]) {
                translatedProperty = @"copy";
            }
            
            if ([attr isEqual:@"&"]) {
                translatedProperty = @"strong";
            }
            
            if ([attr isEqual:@"N"]) {
                translatedProperty = @"nonatomic";
            }
            
            // if ([attr isEqual:@"D"]){ translatedProperty = @"@dynamic"; }
            if ([attr isEqual:@"D"]) {
                continue;
            }
            
            if ([attr isEqual:@"W"]) {
                translatedProperty = @"weak";
            }
            
            if ([attr isEqual:@"P"]) {
                translatedProperty = @"t<encoding>";
            }
            
            [newPropsArray addObject:translatedProperty];
        }
        
        if ([attr rangeOfString:@"G"].location == 0) {
            attr = [attr stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:@""];
            attr = [NSString stringWithFormat:@"getter=%@", attr];
            [newPropsArray addObject:attr];
        }
        
        if ([attr rangeOfString:@"S"].location == 0) {
            attr = [attr stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:@""];
            attr = [NSString stringWithFormat:@"setter=%@", attr];
            [newPropsArray addObject:attr];
        }
    }
    
    //    if ([newPropsArray containsObject:@"nonatomic"] && ![newPropsArray containsObject:@"assign"] &&
    //        ![newPropsArray containsObject:@"readonly"] && ![newPropsArray containsObject:@"copy"] &&
    //        ![newPropsArray containsObject:@"strong"] && ![newPropsArray containsObject:@"weak"]) {
    //        [newPropsArray addObject:@"assign"];
    //    }
    
    newPropsArray = [newPropsArray reverseObjectEnumerator].allObjects.mutableCopy;
    
    NSString *rebuiltString = [newPropsArray componentsJoinedByString:@", "];
    NSString *attrString = [newPropsArray count] > 0 ? [NSString stringWithFormat:@"(%@)", rebuiltString] : @"";
    if ([type hasSuffix:@"*"]) {
        return [[NSString alloc] initWithFormat:@"\n%@%@ %@%@; %@", @"@property ", attrString, type, name, synthesize];
    } else {
        return [[NSString alloc] initWithFormat:@"\n%@%@ %@ %@; %@", @"@property ", attrString, type, name, synthesize];
    }
}

- (NSMutableArray *)buildPropertiesWithString:(NSString *)propertiesString {
    NSMutableArray *propertiesExploded =
    [[propertiesString componentsSeparatedByString:@"\n"] mutableCopy];
    NSMutableArray *typesAndNamesArray = [NSMutableArray array];
    
    for (NSString *string in propertiesExploded) {
        if (string.length < 1) {
            continue;
        }
        
        NSUInteger startlocation = [string rangeOfString:@")"].location;
        NSUInteger endlocation = [string rangeOfString:@";"].location;
        
        if ([string rangeOfString:@";"].location == NSNotFound ||
            [string rangeOfString:@")"].location == NSNotFound) {
            continue;
        }
        
        NSString *propertyTypeFound =
        [string substringWithRange:NSMakeRange(startlocation + 1, endlocation - startlocation - 1)];
        NSUInteger firstSpaceLocationBackwards =
        [propertyTypeFound rangeOfString:@" " options:NSBackwardsSearch].location;
        
        if ([propertyTypeFound rangeOfString:@" " options:NSBackwardsSearch].location == NSNotFound) {
            continue;
        }
        
        NSMutableDictionary *typesAndNames = [NSMutableDictionary dictionary];
        
        NSString *propertyNameFound =
        [propertyTypeFound substringFromIndex:firstSpaceLocationBackwards + 1];
        propertyTypeFound = [propertyTypeFound substringToIndex:firstSpaceLocationBackwards];
        
        // propertyTypeFound=[propertyTypeFound stringByReplacingOccurrencesOfString:@" "
        // withString:@""];
        if ([propertyTypeFound rangeOfString:@" "].location == 0) {
            propertyTypeFound = [propertyTypeFound substringFromIndex:1];
        }
        
        propertyNameFound = [propertyNameFound stringByReplacingOccurrencesOfString:@" "
                                                                         withString:@""];
        
        [typesAndNames setObject:propertyTypeFound forKey:@"type"];
        [typesAndNames setObject:propertyNameFound forKey:@"name"];
        [typesAndNamesArray addObject:typesAndNames];
    }
    
    return typesAndNamesArray;
}

- (NSString *)buildProtocolFile:(Protocol *)currentProtocol {
    NSMutableString *protocolsMethodsString = [[NSMutableString alloc] init];
    
    NSString *protocolName = [NSString stringWithCString:protocol_getName(currentProtocol)
                                                encoding:NSUTF8StringEncoding];
    
    [protocolsMethodsString appendString:[NSString stringWithFormat:@"\n@protocol %@", protocolName]];
    NSMutableArray *classesInProtocol = [[NSMutableArray alloc] init];
    
    unsigned int outCount = 0;
    Protocol *__unsafe_unretained _Nonnull *_Nullable protList = protocol_copyProtocolList(currentProtocol, &outCount);
    
    if (outCount > 0) {
        [protocolsMethodsString appendString:@" <"];
    }
    
    for (int p = 0; p < outCount; p++) {
        NSString *end = p == outCount - 1 ? @"" : @",";
        [protocolsMethodsString
         appendString:[NSString stringWithFormat:@"%s%@", protocol_getName(protList[p]), end]];
    }
    
    if (outCount > 0) {
        [protocolsMethodsString appendString:@">"];
    }
    
    free(protList);
    
    NSMutableString *protPropertiesString = [[NSMutableString alloc] init];
    unsigned int protPropertiesCount;
    
    objc_property_t *protPropertyList =
    protocol_copyPropertyList(currentProtocol, &protPropertiesCount);
    
    for (int xi = 0; xi < protPropertiesCount; xi++) {
        const char *propname = property_getName(protPropertyList[xi]);
        const char *attrs = property_getAttributes(protPropertyList[xi]);
        
        NSCharacterSet *parSet = [NSCharacterSet characterSetWithCharactersInString:@"()"];
        
        NSString *attributes = [[NSString stringWithCString:attrs encoding:NSUTF8StringEncoding]
                                stringByTrimmingCharactersInSet:parSet];
        NSMutableArray *attrArr = (NSMutableArray *)[attributes componentsSeparatedByString:@","];
        NSString *type = [attrArr objectAtIndex:0];
        
        type = [type stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:@""];
        
        if ([type rangeOfString:@"@"].location == 0 &&
            [type rangeOfString:@"\""].location != NSNotFound) {  // E.G. @"NSTimer"
            type = [type stringByReplacingOccurrencesOfString:@"\"" withString:@""];
            type = [type stringByReplacingOccurrencesOfString:@"@" withString:@""];
            type = [type stringByAppendingString:@" *"];
            NSString *classFoundInProperties = [type stringByReplacingOccurrencesOfString:@" *"
                                                                               withString:@""];
            
            if (![classesInProtocol containsObject:classFoundInProperties] &&
                [classFoundInProperties rangeOfString:@"<"].location == NSNotFound) {
                [classesInProtocol addObject:classFoundInProperties];
            }
        }
        
        NSString *newString = [self buildPropertyWithAttributes:[NSString stringWithCString:attrs encoding:NSUTF8StringEncoding] withName:[NSString stringWithCString:propname encoding:NSUTF8StringEncoding]];
        if ([protPropertiesString rangeOfString:newString].location == NSNotFound) {
            [protPropertiesString appendString:newString];
        }
    }
    
    [protocolsMethodsString appendString:protPropertiesString];
    
    free(protPropertyList);
    
    for (int acase = 0; acase < 4; acase++) {
        unsigned int protocolMethodsCount = 0;
        BOOL isRequiredMethod = acase < 2 ? NO : YES;
        BOOL isInstanceMethod = (acase == 0 || acase == 2) ? NO : YES;
        
        struct objc_method_description *protMeths = protocol_copyMethodDescriptionList(
                                                                                       currentProtocol, isRequiredMethod, isInstanceMethod, &protocolMethodsCount);
        
        for (unsigned gg = 0; gg < protocolMethodsCount; gg++) {
            if (acase < 2 && [protocolsMethodsString rangeOfString:@"@optional"].location == NSNotFound) {
                [protocolsMethodsString appendString:@"\n@optional\n"];
            }
            
            if (acase > 1 && [protocolsMethodsString rangeOfString:@"@required"].location == NSNotFound) {
                [protocolsMethodsString appendString:@"\n@required\n"];
            }
            
            NSString *startSign = isInstanceMethod == NO ? @"+" : @"-";
            struct objc_method_description selectorsAndTypes = protMeths[gg];
            SEL selector = selectorsAndTypes.name;
            char *types = selectorsAndTypes.types;
            NSString *protSelector = NSStringFromSelector(selector);
            NSString *finString = @"";
            // CDLog(@"\t\t\t\tAbout to call cd_signatureWithObjCTypes of current protocol with types:
            // %s",types);
            NSMethodSignature *signature = [NSMethodSignature cd_signatureWithObjCTypes:types];
            if (signature == nil) continue;
            // CDLog(@"\t\t\t\tGot cd_signatureWithObjCTypes of current protocol");
            
            NSString *returnTypeString = [NSString stringWithCString:[signature methodReturnType] encoding:NSUTF8StringEncoding];
            NSString *returnType = [self commonTyps:returnTypeString inName:nil inIvarList:NO];
            NSArray *selectorsArray = [protSelector componentsSeparatedByString:@":"];
            
            if (selectorsArray.count > 1) {
                int argCount = 0;
                
                for (unsigned ad = 2; ad < [signature numberOfArguments]; ad++) {
                    argCount++;
                    NSString *space = ad == [signature numberOfArguments] - 1 ? @"" : @" ";
                    NSString *typeString = [NSString stringWithCString:[signature cd_getArgumentTypeAtIndex:ad] encoding:NSUTF8StringEncoding];
                    NSString *argString = [NSString stringWithFormat:@"%@:(%@)arg%d%@", [selectorsArray objectAtIndex:ad - 2], [self commonTyps:typeString inName:nil inIvarList:NO], argCount, space];
                    finString = [finString stringByAppendingString:argString];
                }
            } else {
                finString = [finString
                             stringByAppendingString:[NSString
                                                      stringWithFormat:@"%@", [selectorsArray objectAtIndex:0]]];
            }
            
            finString = [finString stringByAppendingString:@";"];
            [protocolsMethodsString
             appendString:[NSString stringWithFormat:@"%@(%@)%@\n", startSign, returnType, finString]];
        }
        
        free(protMeths);
    }
    
    // FIX EQUAL TYPES OF PROPERTIES AND METHODS
    NSArray *propertiesArray = [self buildPropertiesWithString:protPropertiesString];
    NSArray *lines = [protocolsMethodsString componentsSeparatedByString:@"\n"];
    NSMutableString *finalString = [[NSMutableString alloc] init];
    
    for (NSString __strong *line in lines) {
        if (line.length > 0 &&
            ([line rangeOfString:@"-"].location == 0 || [line rangeOfString:@"+"].location == 0)) {
            NSString *methodInLine = [line substringFromIndex:[line rangeOfString:@")"].location + 1];
            methodInLine = [methodInLine substringToIndex:[methodInLine rangeOfString:@";"].location];
            
            for (NSDictionary *dict in propertiesArray) {
                NSString *propertyName = [dict objectForKey:@"name"];
                
                if ([methodInLine rangeOfString:@"set"].location != NSNotFound) {
                    NSString *firstCapitalized = [[propertyName substringToIndex:1] capitalizedString];
                    NSString *capitalizedFirst =
                    [firstCapitalized stringByAppendingString:[propertyName substringFromIndex:1]];
                    
                    if ([methodInLine isEqual:[NSString stringWithFormat:@"set%@", capitalizedFirst]]) {
                        // replace setter
                        NSString *newLine = [line substringToIndex:[line rangeOfString:@":("].location + 2];
                        newLine = [newLine stringByAppendingString:[dict objectForKey:@"type"]];
                        newLine = [newLine
                                   stringByAppendingString:[line substringFromIndex:[line rangeOfString:@")" options:4]
                                                            .location]];
                        line = newLine;
                    }
                }
                
                if ([methodInLine isEqual:propertyName]) {
                    NSString *newLine = [line substringToIndex:[line rangeOfString:@"("].location + 1];
                    newLine = [newLine
                               stringByAppendingString:[NSString stringWithFormat:@"%@)%@;",
                                                        [dict objectForKey:@"type"],
                                                        [dict objectForKey:@"name"]]];
                    line = newLine;
                }
            }
        }
        
        [finalString appendString:[line stringByAppendingString:@"\n"]];
    }
    
    if ([classesInProtocol count] > 0) {
        NSMutableString *classesFoundToAdd = [[NSMutableString alloc] init];
        [classesFoundToAdd appendString:@"@class "];
        
        for (int f = 0; f < classesInProtocol.count; f++) {
            NSString *classFound = [classesInProtocol objectAtIndex:f];
            
            if (f < classesInProtocol.count - 1) {
                [classesFoundToAdd appendString:[NSString stringWithFormat:@"%@, ", classFound]];
            } else {
                [classesFoundToAdd appendString:[NSString stringWithFormat:@"%@;", classFound]];
            }
        }
        
        [classesFoundToAdd appendString:@"\n\n"];
        [classesFoundToAdd appendString:finalString];
        finalString = [classesFoundToAdd mutableCopy];
    }
    
    [finalString appendString:@"@end\n\n"];
    return finalString;
}

- (NSString *)representedStructFromStruct:(NSString *)inStruct inName:(NSString *)inName inIvarList:(BOOL)inIvarList isFinal:(BOOL)isFinal {
    if ([inStruct rangeOfString:@"\""].location == NSNotFound) { // not an ivar type struct, it has the names of types in quotes
        if ([inStruct rangeOfString:@"{?="].location == 0) {
            // UNKNOWN TYPE, WE WILL CONSTRUCT IT
            
            NSString *types = [inStruct substringFromIndex:3];
            types = [types substringToIndex:types.length - 1];
            
            for (NSDictionary *dict in self.allStructsFound) {
                if ([[dict objectForKey:@"types"] isEqual:types]) {
                    return [dict objectForKey:@"name"];
                }
            }
            
            __block NSMutableArray *strctArray = [NSMutableArray array];
            
            while ([types rangeOfString:@"{"].location != NSNotFound) {
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\{([^\\{^\\}]+)\\}" options:NSRegularExpressionCaseInsensitive error:nil];
                __block NSString *blParts = nil;
                //(?=d{})QQddQ <-- this particular 'types' would cause a segfault/crash and now causes an infinite loop
                [regex enumerateMatchesInString:types options:0
                                          range:NSMakeRange(0, [types length])
                                     usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
                 {
                    for (int i = 1; i < [result numberOfRanges]; ) {
                        NSString *stringToPut = [self representedStructFromStruct:[NSString stringWithFormat:@"{%@}", [types substringWithRange:[result rangeAtIndex:i]]] inName:nil inIvarList:NO isFinal:NO];
                        blParts = [types stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}", [types substringWithRange:[result rangeAtIndex:i]]] withString:stringToPut];
                        
                        if ([blParts rangeOfString:@"{"].location == NSNotFound) {
                            [strctArray addObject:stringToPut];
                        }
                        
                        break;
                    }
                }];
                
                if (blParts) { //if its not found, blParts is nil and will break things.
                    types = blParts;
                } else {
                    //this might not be an end all be all, but it fixes it for this types: (?=d{})QQddQ
                    types = [types stringByReplacingOccurrencesOfString:@"{}" withString:@""];
                }
            }
            NSMutableArray *alreadyFoundStructs = [NSMutableArray array];
            
            for (NSDictionary *dict in self.allStructsFound) {
                if ([types rangeOfString:[dict objectForKey:@"name"]].location != NSNotFound || [types rangeOfString:@"CFDictionary"].location != NSNotFound) {
                    BOOL isCFDictionaryHackException = 0;
                    NSString *str;
                    
                    if ([types rangeOfString:@"CFDictionary"].location != NSNotFound) {
                        str = @"CFDictionary";
                        isCFDictionaryHackException = 1;
                    } else {
                        str = [dict objectForKey:@"name"];
                    }
                    
                    while ([types rangeOfString:str].location != NSNotFound) {
                        if ([str isEqual:@"CFDictionary"]) {
                            [alreadyFoundStructs addObject:@"void*"];
                        } else {
                            [alreadyFoundStructs addObject:str];
                        }
                        
                        NSUInteger replaceLocation = [types rangeOfString:str].location;
                        NSUInteger replaceLength = str.length;
                        types = [types stringByReplacingCharactersInRange:NSMakeRange(replaceLocation, replaceLength) withString:@"+"];
                    }
                }
            }
            
            __block NSMutableArray *arrArray = [NSMutableArray array];
            
            while ([types rangeOfString:@"["].location != NSNotFound) {
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\[^\\]]+)\\]" options:NSRegularExpressionCaseInsensitive error:nil];
                __block NSString *blParts2;
                
                [regex enumerateMatchesInString:types options:0
                                          range:NSMakeRange(0, [types length])
                                     usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
                 {
                    for (int i = 1; i < [result numberOfRanges]; ) {
                        NSString *stringToPut = [NSString stringWithFormat:@"[%@]", [types substringWithRange:[result rangeAtIndex:i]]];
                        NSRange range = [types rangeOfString:stringToPut];
                        
                        blParts2 = [types stringByReplacingCharactersInRange:NSMakeRange(range.location, range.length) withString:@"~"];
                        [arrArray addObject:stringToPut];
                        
                        *stop = 1;
                        break;
                    }
                }];
                
                types = blParts2;
            }
            __block NSMutableArray *bitArray = [NSMutableArray array];
            
            while ([types rangeOfString:@"b1"].location != NSNotFound || [types rangeOfString:@"b2"].location != NSNotFound || [types rangeOfString:@"b3"].location != NSNotFound || [types rangeOfString:@"b4"].location != NSNotFound || [types rangeOfString:@"b5"].location != NSNotFound || [types rangeOfString:@"b6"].location != NSNotFound || [types rangeOfString:@"b7"].location != NSNotFound || [types rangeOfString:@"b8"].location != NSNotFound || [types rangeOfString:@"b9"].location != NSNotFound) {
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(b[0-9]+)" options:0 error:nil];
                __block NSString *blParts3;
                [regex enumerateMatchesInString:types options:0
                                          range:NSMakeRange(0, [types length])
                                     usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
                 {
                    for (int i = 1; i < [result numberOfRanges]; ) {
                        NSString *stringToPut = [types substringWithRange:[result rangeAtIndex:i]];
                        blParts3 = [types stringByReplacingOccurrencesOfString:[types substringWithRange:[result rangeAtIndex:i]] withString:@"§"];
                        [bitArray addObject:stringToPut];
                        break;
                    }
                }];
                
                types = blParts3;
            }
            
            for (NSString *string in strctArray) {
                if ([types rangeOfString:string].location == NSNotFound) {
                    break;
                }
                
                NSUInteger loc = [types rangeOfString:string].location;
                NSUInteger length = string.length;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, length) withString:@"!"];
            }
            
            int fieldCount = 0;
            
            for (int i = 0; i < types.length; i++) {
                NSString *string = [types substringWithRange:NSMakeRange(i, 1)];
                
                if (![string isEqual:@"["] && ![string isEqual:@"]"] && ![string isEqual:@"{"] && ![string isEqual:@"}"] && ![string isEqual:@"\""] && ![string isEqual:@"b"] && ![string isEqual:@"("] && ![string isEqual:@")"]) {
                    fieldCount++;
                    NSString *newString = [NSString stringWithFormat:@"\"field%d\"%@", fieldCount, [self commonTyps:string inName:nil inIvarList:NO]];
                    types = [types stringByReplacingCharactersInRange:NSMakeRange(i, 1) withString:[NSString stringWithFormat:@"\"field%d\"%@", fieldCount, [self commonTyps:string inName:nil inIvarList:NO]]];
                    i += newString.length - 1;
                }
            }
            
            int fCounter = -1; // Separate counters used for debugging purposes
            
            while ([types rangeOfString:@"!"].location != NSNotFound) {
                fCounter++;
                NSUInteger loc = [types rangeOfString:@"!"].location;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, 1) withString:[strctArray objectAtIndex:fCounter]];
            }
            int fCounter2 = -1;
            
            while ([types rangeOfString:@"~"].location != NSNotFound) {
                fCounter2++;
                NSUInteger loc = [types rangeOfString:@"~"].location;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, 1) withString:[arrArray objectAtIndex:fCounter2]];
            }
            int fCounter3 = -1;
            
            while ([types rangeOfString:@"§"].location != NSNotFound) {
                fCounter3++;
                NSUInteger loc = [types rangeOfString:@"§"].location;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, 1) withString:[bitArray objectAtIndex:fCounter3]];
            }
            int fCounter4 = -1;
            
            while ([types rangeOfString:@"+"].location != NSNotFound) {
                fCounter4++;
                NSUInteger loc = [types rangeOfString:@"+"].location;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, 1) withString:[alreadyFoundStructs objectAtIndex:fCounter4]];
            }
            NSString *whatIBuilt = [NSString stringWithFormat:@"{?=%@}", types];
            
            if ([whatIBuilt isEqualToString:@"{?=}"]) {
                return whatIBuilt;
            }
            
            NSString *whatIReturn = [self representedStructFromStruct:whatIBuilt inName:nil inIvarList:NO isFinal:YES];
            return whatIReturn;
        } else {
            if ([inStruct rangeOfString:@"="].location == NSNotFound) {
                inStruct = [inStruct stringByReplacingOccurrencesOfString:@"{" withString:@""];
                inStruct = [inStruct stringByReplacingOccurrencesOfString:@"}" withString:@""];
                return inStruct;
            }
            
            NSUInteger firstIson = [inStruct rangeOfString:@"="].location;
            inStruct = [inStruct substringToIndex:firstIson];
            
            inStruct = [inStruct substringFromIndex:1];
            return inStruct;
        }
    }
    
    NSUInteger firstBrace = [inStruct rangeOfString:@"{"].location;
    NSUInteger ison = [inStruct rangeOfString:@"="].location;
    NSString *structName = [inStruct substringWithRange:NSMakeRange(firstBrace + 1, ison - 1)];
    
    NSString *parts = [inStruct substringFromIndex:ison + 1];
    parts = [parts substringToIndex:parts.length - 1]; // remove last character "}"
    if ([parts rangeOfString:@"{"].location == NSNotFound) { //does not contain other struct
        if ([ClassDumpDyldHelper hasMalformedIDWithParts:parts]) {
            while ([parts rangeOfString:@"@"].location != NSNotFound && [ClassDumpDyldHelper hasMalformedIDWithParts:parts]) {
                NSString *trialString = [parts substringFromIndex:[parts rangeOfString:@"@"].location + 2];
                
                if ([trialString rangeOfString:@"\""].location != [trialString rangeOfString:@"\"\""].location && [trialString rangeOfString:@"\""].location != trialString.length - 1 && [trialString rangeOfString:@"]"].location != [trialString rangeOfString:@"\""].location + 1) {
                    NSUInteger location = [parts rangeOfString:@"@"].location;
                    parts = [parts stringByReplacingCharactersInRange:NSMakeRange(location - 1, 3) withString:@"\"id\""];
                }
                
                NSUInteger location = [parts rangeOfString:@"@"].location;
                
                if ([parts rangeOfString:@"@"].location != NSNotFound) {
                    NSString *asubstring = [parts substringFromIndex:location + 2];
                    
                    NSUInteger nextlocation = [asubstring rangeOfString:@"\""].location;
                    asubstring = [asubstring substringWithRange:NSMakeRange(0, nextlocation)];
                    
                    if ([self.classesInStructs indexOfObject:asubstring] == NSNotFound) {
                        [self.classesInStructs addObject:asubstring];
                    }
                    
                    parts = [parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"@\"%@\"", asubstring] withString:[NSString stringWithFormat:@"^%@", asubstring]];
                }
            }
        }
        
        NSMutableArray *brokenParts = [[parts componentsSeparatedByString:@"\""] mutableCopy];
        [brokenParts removeObjectAtIndex:0];
        NSString *types = @"";
        
        BOOL reallyIsFlagInIvars = 0;
        
        if (inIvarList && [inName rangeOfString:@"flags" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            reallyIsFlagInIvars = 1;
        }
        
        BOOL wasKnown = 1;
        
        if ([structName isEqual:@"?"]) {
            wasKnown = 0;
            structName = [NSString stringWithFormat:@"SCD_Struct_%@%d", self.classID, (int)[self.allStructsFound count]];
        }
        
        if ([structName rangeOfString:@"_"].location == 0) {
            structName = [structName substringFromIndex:1];
        }
        
        NSString *representation = reallyIsFlagInIvars ? @"struct {\n" : (wasKnown ? [NSString stringWithFormat:@"typedef struct %@ {\n", structName] : @"typedef struct {\n");
        
        for (int i = 0; i < [brokenParts count] - 1; i += 2) { // always an even number
            NSString *nam = [brokenParts objectAtIndex:i];
            NSString *typ = [brokenParts objectAtIndex:i + 1];
            types = [types stringByAppendingString:[brokenParts objectAtIndex:i + 1]];
            representation = reallyIsFlagInIvars ? [representation stringByAppendingString:[NSString stringWithFormat:@"\t\t%@ %@;\n", [self commonTyps:typ inName:&nam inIvarList:NO], nam]] : [representation stringByAppendingString:[NSString stringWithFormat:@"\t%@ %@;\n", [self commonTyps:typ inName:&nam inIvarList:NO], nam]];
        }
        
        representation = reallyIsFlagInIvars ? [representation stringByAppendingString:@"\t} "] : [representation stringByAppendingString:@"} "];
        
        if ([structName rangeOfString:@"_"].location == 0) {
            structName = [structName substringFromIndex:1];
        }
        
        if ([structName rangeOfString:@"_"].location == 0) {
            structName = [structName substringFromIndex:1];
        }
        
        representation = reallyIsFlagInIvars ? representation : [representation stringByAppendingString:[NSString stringWithFormat:@"%@;\n\n", structName]];
        
        if (isFinal && !reallyIsFlagInIvars) {
            for (NSMutableDictionary *dict in self.allStructsFound) {
                if ([[dict objectForKey:@"types"] isEqual:types] && !wasKnown && ![[dict objectForKey:@"name"] isEqual:[dict objectForKey:@"types"]]) {
                    NSString *repr = [dict objectForKey:@"representation"];
                    
                    if ([repr rangeOfString:@"field"].location != NSNotFound && [representation rangeOfString:@"field"].location == NSNotFound && ![structName isEqual:types]) {
                        representation = [representation stringByReplacingOccurrencesOfString:structName withString:[dict objectForKey:@"name"]];
                        [dict setObject:representation forKey:@"representation"];
                        structName = [dict objectForKey:@"name"];
                        
                        break;
                    }
                }
            }
        }
        
        BOOL found = NO;
        
        for (NSDictionary *dict in self.allStructsFound) {
            if ([[dict objectForKey:@"name"] isEqual:structName]) {
                found = YES;
                return structName;
                
                break;
            }
        }
        
        if (!found) {
            for (NSMutableDictionary *dict in self.allStructsFound) {
                if ([[dict objectForKey:@"types"] isEqual:types] && !wasKnown) {
                    found = YES;
                    return [dict objectForKey:@"name"];
                }
            }
        }
        
        if (!found && !reallyIsFlagInIvars) {
            [self.allStructsFound addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:representation, @"representation", structName, @"name", types, @"types", nil]];
        }
        
        return reallyIsFlagInIvars ? representation : structName;
    } else {
        // contains other structs,attempt to break apart
        
        while ([parts rangeOfString:@"{"].location != NSNotFound) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\{([^\\{^\\}]+)\\}" options:NSRegularExpressionCaseInsensitive error:nil];
            __block NSString *blParts;
            [regex enumerateMatchesInString:parts options:0
                                      range:NSMakeRange(0, [parts length])
                                 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
             {
                for (int i = 1; i < [result numberOfRanges];) {
                    NSString *string = [self representedStructFromStruct:[NSString stringWithFormat:@"{%@}", [parts substringWithRange:[result rangeAtIndex:i]]] inName:nil inIvarList:NO isFinal:NO];
                    blParts = [parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}", [parts substringWithRange:[result rangeAtIndex:i]]] withString:string];
                    break;
                }
            }];
            parts = blParts;
        }
        NSString *rebuiltStruct = [NSString stringWithFormat:@"{%@=%@}", structName, parts];
        NSString *final = [self representedStructFromStruct:rebuiltStruct inName:nil inIvarList:NO isFinal:YES];
        return final;
    }
    
    return inStruct;
}

- (NSString *)representedUnionFromUnion:(NSString *)inUnion {
    if ([inUnion rangeOfString:@"\""].location == NSNotFound) {
        if ([inUnion rangeOfString:@"{?="].location == 0) {
            NSString *types = [inUnion substringFromIndex:3];
            types = [types substringToIndex:types.length - 1];
            
            for (NSDictionary *dict in self.allStructsFound) {
                if ([[dict objectForKey:@"types"] isEqual:types]) {
                    return [dict objectForKey:@"name"];
                }
            }
            
            return inUnion;
        } else {
            if ([inUnion rangeOfString:@"="].location == NSNotFound) {
                inUnion = [inUnion stringByReplacingOccurrencesOfString:@"{" withString:@""];
                inUnion = [inUnion stringByReplacingOccurrencesOfString:@"}" withString:@""];
                return inUnion;
            }
            
            NSUInteger firstIson = [inUnion rangeOfString:@"="].location;
            inUnion = [inUnion substringToIndex:firstIson];
            inUnion = [inUnion substringFromIndex:1];
            return inUnion;
        }
    }
    
    NSUInteger firstParenthesis = [inUnion rangeOfString:@"("].location;
    NSUInteger ison = [inUnion rangeOfString:@"="].location;
    NSString *unionName = [inUnion substringWithRange:NSMakeRange(firstParenthesis + 1, ison - 1)];
    
    NSString *parts = [inUnion substringFromIndex:ison + 1];
    parts = [parts substringToIndex:parts.length - 1];  // remove last character "}"
    
    if ([parts rangeOfString:@"\"\"{"].location != NSNotFound) {
        parts = [parts stringByReplacingOccurrencesOfString:@"\"\"{" withString:@"\"field0\"{"];
    }
    
    if ([parts rangeOfString:@"("].location != NSNotFound) {
        while ([parts rangeOfString:@"("].location != NSNotFound) {
            NSRegularExpression *regex =
            [NSRegularExpression regularExpressionWithPattern:@"\\(([^\\(^\\)]+)\\)"
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:nil];
            __block NSString *unionParts;
            [regex
             enumerateMatchesInString:parts
             options:0
             range:NSMakeRange(0, [parts length])
             usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags,
                          BOOL *stop) {
                for (NSUInteger i = 1; i < [result numberOfRanges]; ) {
                    unionParts = [parts
                                  stringByReplacingOccurrencesOfString:
                                      [NSString stringWithFormat:@"(%@)",
                                       [parts substringWithRange:
                                        [result rangeAtIndex:i]]]
                                  withString:[self representedUnionFromUnion:[NSString
                                                                              stringWithFormat:
                                                                                  @"(%@)",
                                                                              [parts
                                                                               substringWithRange:
                                                                                   [result rangeAtIndex:
                                                                                    i]]]]];
                    break;
                }
            }];
            parts = unionParts;
        }
    }
    
    if ([parts rangeOfString:@"{"].location != NSNotFound) {
        while ([parts rangeOfString:@"{"].location != NSNotFound) {
            NSRegularExpression *regex =
            [NSRegularExpression regularExpressionWithPattern:@"\\{([^\\{^\\}]+)\\}"
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:nil];
            __block NSString *structParts;
            [regex
             enumerateMatchesInString:parts
             options:0
             range:NSMakeRange(0, [parts length])
             usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags,
                          BOOL *stop) {
                for (NSUInteger i = 1; i < [result numberOfRanges]; ) {
                    NSString *string = [self representedStructFromStruct:[NSString stringWithFormat:@"{%@}", [parts substringWithRange:[result rangeAtIndex:i]]] inName:nil inIvarList:NO isFinal:NO];
                    structParts = [parts stringByReplacingOccurrencesOfString: [NSString stringWithFormat:@"{%@}", [parts substringWithRange:[result rangeAtIndex:i]]] withString:string];
                    break;
                }
            }];
            parts = structParts;
        }
    }
    
    if ([ClassDumpDyldHelper hasMalformedIDWithParts:parts]) {
        while ([parts rangeOfString:@"@"].location != NSNotFound && [ClassDumpDyldHelper hasMalformedIDWithParts:parts]) {
            NSString *trialString = [parts substringFromIndex:[parts rangeOfString:@"@"].location + 2];
            
            if ([trialString rangeOfString:@"\""].location !=
                [trialString rangeOfString:@"\"\""].location &&
                [trialString rangeOfString:@"\""].location != trialString.length - 1 &&
                [trialString rangeOfString:@"]"].location !=
                [trialString rangeOfString:@"\""].location + 1) {
                NSUInteger location = [parts rangeOfString:@"@"].location;
                parts = [parts stringByReplacingCharactersInRange:NSMakeRange(location - 1, 3)
                                                       withString:@"\"id\""];
            }
            
            NSUInteger location = [parts rangeOfString:@"@"].location;
            
            if ([parts rangeOfString:@"@"].location != NSNotFound) {
                NSString *asubstring = [parts substringFromIndex:location + 2];
                
                NSUInteger nextlocation = [asubstring rangeOfString:@"\""].location;
                asubstring = [asubstring substringWithRange:NSMakeRange(0, nextlocation)];
                
                if ([self.classesInStructs indexOfObject:asubstring] == NSNotFound) {
                    [self.classesInStructs addObject:asubstring];
                }
                
                parts = [parts
                         stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"@\"%@\"", asubstring]
                         withString:[NSString stringWithFormat:@"^%@", asubstring]];
            }
        }
    }
    
    NSMutableArray *brokenParts = [[parts componentsSeparatedByString:@"\""] mutableCopy];
    [brokenParts removeObjectAtIndex:0];
    NSString *types = @"";
    
    BOOL wasKnown = 1;
    
    if ([unionName isEqual:@"?"]) {
        wasKnown = 0;
        unionName =
        [NSString stringWithFormat:@"SCD_Union_%@%d", self.classID, (int)[self.allStructsFound count]];
    }
    
    if ([unionName rangeOfString:@"_"].location == 0) {
        unionName = [unionName substringFromIndex:1];
    }
    
    NSString *representation = wasKnown
    ? [NSString stringWithFormat:@"typedef union %@ {\n", unionName]
    : @"typedef union {\n";
    int upCount = 0;
    
    for (int i = 0; i < [brokenParts count] - 1; i += 2) {  // always an even number
        NSString *nam = [brokenParts objectAtIndex:i];
        upCount++;
        
        if ([nam rangeOfString:@"field0"].location != NSNotFound) {
            nam = [nam
                   stringByReplacingOccurrencesOfString:@"field0"
                   withString:[NSString stringWithFormat:@"field%d", upCount]];
        }
        
        NSString *typ = [brokenParts objectAtIndex:i + 1];
        types = [types stringByAppendingString:[brokenParts objectAtIndex:i + 1]];
        representation = [representation stringByAppendingString:[NSString stringWithFormat:@"\t%@ %@;\n", [self commonTyps:typ inName:&nam inIvarList:NO], nam]];
    }
    
    representation = [representation stringByAppendingString:@"} "];
    representation =
    [representation stringByAppendingString:[NSString stringWithFormat:@"%@;\n\n", unionName]];
    BOOL found = NO;
    
    for (NSDictionary *dict in self.allStructsFound) {
        if ([[dict objectForKey:@"name"] isEqual:unionName]) {
            found = YES;
            return unionName;
            
            break;
        }
    }
    
    if (!found) {
        for (NSDictionary *dict in self.allStructsFound) {
            if ([[dict objectForKey:@"types"] isEqual:types] && !wasKnown) {
                found = YES;
                return [dict objectForKey:@"name"];
                
                break;
            }
        }
    }
    
    [self.allStructsFound addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:representation, @"representation", unionName, @"name", types, @"types", nil]];
    
    return unionName != nil ? unionName : inUnion;
}

- (NSString *)commonTyps:(NSString *)atype inName:(NSString *__autoreleasing *)inName inIvarList:(BOOL)inIvarList {
    BOOL isRef = NO;
    BOOL isPointer = NO;
    BOOL isCArray = NO;
    BOOL isConst = NO;
    BOOL isOut = NO;
    BOOL isByCopy = NO;
    BOOL isByRef = NO;
    BOOL isOneWay = NO;
    
    /* Stripping off any extra identifiers to leave only the actual type for parsing later on */
    
    if ([atype rangeOfString:@"o"].location == 0 &&
        ![[self commonTyps:[atype substringFromIndex:1] inName:nil inIvarList:NO] isEqual:[atype substringFromIndex:1]]) {
        isOut = YES;
        atype = [atype substringFromIndex:1];
    }
    
    if ([atype rangeOfString:@"O"].location == 0 &&
        ![[self commonTyps:[atype substringFromIndex:1] inName:nil inIvarList:NO] isEqual:[atype substringFromIndex:1]]) {
        isByCopy = YES;
        atype = [atype substringFromIndex:1];
    }
    
    if ([atype rangeOfString:@"R"].location == 0 &&
        ![[self commonTyps:[atype substringFromIndex:1] inName:nil inIvarList:NO] isEqual:[atype substringFromIndex:1]]) {
        isByRef = YES;
        atype = [atype substringFromIndex:1];
    }
    
    if ([atype rangeOfString:@"V"].location == 0 &&
        ![[self commonTyps:[atype substringFromIndex:1] inName:nil inIvarList:NO] isEqual:[atype substringFromIndex:1]]) {
        isOneWay = YES;
        atype = [atype substringFromIndex:1];
    }
    
    if ([atype rangeOfString:@"r^{"].location == 0) {
        isConst = YES;
        atype = [atype substringFromIndex:2];
        isPointer = YES;
        self.shouldImportStructs = 1;
    }
    
    if ([atype rangeOfString:@"r"].location == 0) {
        isConst = YES;
        atype = [atype substringFromIndex:1];
    }
    
    if ([atype isEqual:@"^?"]) {
        atype = @"/*function pointer*/void*";
    }
    
    if ([atype rangeOfString:@"^"].location != NSNotFound) {
        isPointer = YES;
        atype = [atype stringByReplacingOccurrencesOfString:@"^" withString:@""];
    }
    
    if ([atype rangeOfString:@"("].location == 0) {
        atype = [self representedUnionFromUnion:atype];
    }
    
    int arrayCount = 0;
    
    if ([atype rangeOfString:@"["].location == 0) {
        isCArray = YES;
        
        if ([atype rangeOfString:@"{"].location != NSNotFound) {
            atype = [atype stringByReplacingOccurrencesOfString:@"[" withString:@""];
            atype = [atype stringByReplacingOccurrencesOfString:@"]" withString:@""];
            NSUInteger firstBrace = [atype rangeOfString:@"{"].location;
            arrayCount = [[atype
                           stringByReplacingCharactersInRange:NSMakeRange(firstBrace, atype.length - firstBrace)
                           withString:@""] intValue];
            atype = [atype stringByReplacingCharactersInRange:NSMakeRange(0, firstBrace) withString:@""];
        } else {
            isCArray = NO;
            NSRegularExpressionOptions opt = 0;
            
            __block NSString *tempString = [atype mutableCopy];
            __block NSMutableArray *numberOfArray = [NSMutableArray array];
            
            while ([tempString rangeOfString:@"["].location != NSNotFound) {
                NSRegularExpression *regex =
                [NSRegularExpression regularExpressionWithPattern:@"(\\[([^\\[^\\]]+)\\])"
                                                          options:opt
                                                            error:nil];
                
                [regex enumerateMatchesInString:tempString
                                        options:0
                                          range:NSMakeRange(0, [tempString length])
                                     usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags,
                                                  BOOL *stop) {
                    for (NSUInteger i = 1; i < [result numberOfRanges]; ) {
                        NSString *foundString =
                        [tempString substringWithRange:[result rangeAtIndex:i]];
                        tempString =
                        [tempString stringByReplacingOccurrencesOfString:foundString
                                                              withString:@""];
                        [numberOfArray addObject:foundString];  // e.g. [2] or [100c]
                        break;
                    }
                }];
            }
            
            NSString *stringContainingType = nil;
            
            for (NSString *aString in numberOfArray) {
                NSCharacterSet *set = [[NSCharacterSet
                                        characterSetWithCharactersInString:
                                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLKMNOPQRSTUVWXYZ@#$%^&*()!<>?:\"|}{"]
                                       invertedSet];
                
                if ([aString rangeOfCharacterFromSet:set].location != NSNotFound) {
                    stringContainingType = aString;
                    break;
                }
            }
            
            [numberOfArray removeObject:stringContainingType];
            NSCharacterSet *set = [NSCharacterSet
                                   characterSetWithCharactersInString:
                                       @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLKMNOPQRSTUVWXYZ@#$%^&*()!<>?:\"|}{"];
            NSUInteger letterLocation = [stringContainingType rangeOfCharacterFromSet:set].location == NSNotFound
            ? -1
            : [stringContainingType rangeOfCharacterFromSet:set].location;
            NSString *outtype = letterLocation == -1
            ? stringContainingType
            : [stringContainingType substringFromIndex:letterLocation];
            outtype = [outtype stringByReplacingOccurrencesOfString:@"]" withString:@""];
            stringContainingType = [stringContainingType stringByReplacingOccurrencesOfString:outtype
                                                                                   withString:@""];
            
            for (NSString *subarr in numberOfArray) {
                stringContainingType = [subarr stringByAppendingString:stringContainingType];
            }
            
            atype = outtype;
            
            if ([atype isEqual:@"v"]) {
                atype = @"void*";
            }
            
            if (inName != nil) {
                *inName = [*inName stringByAppendingString:stringContainingType];
            }
        }
    }
    
    if ([atype rangeOfString:@"=}"].location != NSNotFound &&
        [atype rangeOfString:@"{"].location == 0 &&
        [atype rangeOfString:@"?"].location == NSNotFound &&
        [atype rangeOfString:@"\""].location == NSNotFound) {
        self.shouldImportStructs = 1;
        NSString *writeString = [atype stringByReplacingOccurrencesOfString:@"{" withString:@""];
        writeString = [writeString stringByReplacingOccurrencesOfString:@"}" withString:@""];
        writeString = [writeString stringByReplacingOccurrencesOfString:@"=" withString:@""];
        NSString *constString = isConst ? @"const " : @"";
        writeString = [NSString stringWithFormat:@"typedef %@struct %@* ", constString, writeString];
        
        atype = [atype stringByReplacingOccurrencesOfString:@"{__" withString:@""];
        atype = [atype stringByReplacingOccurrencesOfString:@"{" withString:@""];
        atype = [atype stringByReplacingOccurrencesOfString:@"=}" withString:@""];
        
        if ([atype rangeOfString:@"_"].location == 0) {
            atype = [atype substringFromIndex:1];
        }
        
        BOOL found = NO;
        
        for (NSDictionary *dict in self.allStructsFound) {
            if ([[dict objectForKey:@"name"] isEqual:atype]) {
                found = YES;
                break;
            }
        }
        
        if (!found) {
            NSString *appendingString = [NSString stringWithFormat:@"%@Ref;\n\n", [self representedStructFromStruct:atype inName:nil inIvarList:NO isFinal:NO]];
            writeString = [writeString stringByAppendingString:appendingString];
            [self.allStructsFound addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObject:@""], @"types", writeString, @"representation", atype, @"name", nil]];
        }
        
        isRef = YES;
        isPointer = NO;  // -> Ref
    }
    
    if ([atype rangeOfString:@"{"].location == 0) {
        if (inName != nil) {
            atype = [self representedStructFromStruct:atype inName:*inName inIvarList:inIvarList isFinal:inIvarList];
        } else {
            atype = [self representedStructFromStruct:atype inName:nil inIvarList:inIvarList isFinal:YES];
        }
        
        if ([atype rangeOfString:@"_"].location == 0) {
            atype = [atype substringFromIndex:1];
        }
        
        self.shouldImportStructs = 1;
    }
    
    if ([atype rangeOfString:@"b"].location == 0 && atype.length > 1) {
        NSCharacterSet *numberSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
        
        if ([atype rangeOfCharacterFromSet:numberSet].location == 1) {
            NSString *bitValue = [atype substringFromIndex:1];
            atype = @"unsigned";
            
            if (inName != nil) {
                *inName = [*inName stringByAppendingString:[NSString stringWithFormat:@" : %@", bitValue]];
            }
        }
    }
    
    if ([atype rangeOfString:@"N"].location == 0 &&
        ![[self commonTyps:[atype substringFromIndex:1] inName:nil inIvarList:NO] isEqual:[atype substringFromIndex:1]]) {
        atype = [self commonTyps:[atype substringFromIndex:1] inName:nil inIvarList:NO];
        atype = [NSString stringWithFormat:@"inout %@", atype];
    }
    
    if ([atype isEqual:@"d"]) {
        atype = @"double";
    }
    
    if ([atype isEqual:@"i"]) {
        atype = @"int";
    }
    
    if ([atype isEqual:@"f"]) {
        atype = @"float";
    }
    
    if ([atype isEqual:@"c"]) {
        atype = @"char";
    }
    
    if ([atype isEqual:@"s"]) {
        atype = @"short";
    }
    
    if ([atype isEqual:@"I"]) {
        atype = @"unsigned";
    }
    
    if ([atype isEqual:@"l"]) {
        atype = @"long";
    }
    
    if ([atype isEqual:@"q"]) {
        atype = @"long long";
    }
    
    if ([atype isEqual:@"L"]) {
        atype = @"unsigned long";
    }
    
    if ([atype isEqual:@"C"]) {
        atype = @"unsigned char";
    }
    
    if ([atype isEqual:@"S"]) {
        atype = @"unsigned short";
    }
    
    if ([atype isEqual:@"Q"]) {
        atype = @"unsigned long long";
    }
    
    // if ([atype isEqual:  @"Q"]){ atype = @"uint64_t"; }
    
    if ([atype isEqual:@"B"]) {
        atype = @"BOOL";
    }
    
    if ([atype isEqual:@"v"]) {
        atype = @"void";
    }
    
    if ([atype isEqual:@"*"]) {
        atype = @"char*";
    }
    
    if ([atype isEqual:@":"]) {
        atype = @"SEL";
    }
    
    if ([atype isEqual:@"?"]) {
        atype = @"/*function pointer*/void*";
    }
    
    if ([atype isEqual:@"#"]) {
        atype = @"Class";
    }
    
    if ([atype isEqual:@"@"]) {
        atype = @"id";
    }
    
    if ([atype isEqual:@"@?"]) {
        atype = @"/*^block*/id";
    }
    
    if ([atype isEqual:@"Vv"]) {
        atype = @"void";
    }
    
    if ([atype isEqual:@"rv"]) {
        atype = @"const void*";
    }
    
    if (isRef) {
        if ([atype rangeOfString:@"_"].location == 0) {
            atype = [atype substringFromIndex:1];
        }
        
        atype = [atype isEqual:@"NSZone"] ? @"NSZone*" : [atype stringByAppendingString:@"Ref"];
    }
    
    if (isPointer) {
        atype = [atype stringByAppendingString:@"*"];
    }
    
    if (isConst) {
        atype = [@"const " stringByAppendingString:atype];
    }
    
    if (isCArray &&
        inName !=
        nil) {  // more checking to do, some framework were crashing if not nil, shouldn't be nil
        *inName = [*inName stringByAppendingString:[NSString stringWithFormat:@"[%d]", arrayCount]];
    }
    
    if (isOut) {
        atype = [@"out " stringByAppendingString:atype];
    }
    
    if (isByCopy) {
        atype = [@"bycopy " stringByAppendingString:atype];
    }
    
    if (isByRef) {
        atype = [@"byref " stringByAppendingString:atype];
    }
    
    if (isOneWay) {
        atype = [@"oneway " stringByAppendingString:atype];
    }
    
    return atype;
}

- (NSString *)buildMethodsWithClass:(Class)someclass isInstanceMethod:(BOOL)isInstanceMethod withProperties:(NSMutableArray *)propertiesArray {
    unsigned int outCount;
    
    NSString *returnString = @"";
    Method *methodsArray = class_copyMethodList(someclass, &outCount);
    
    for (unsigned x = 0; x < outCount; x++) {
        Method currentMethod = methodsArray[x];
        SEL sele = method_getName(currentMethod);
        unsigned methodArgs = method_getNumberOfArguments(currentMethod);
        char *returnType = method_copyReturnType(currentMethod);
        const char *selectorName = sel_getName(sele);
        NSString *returnTypeSameAsProperty = nil;
        
        NSString *SelectorNameNS = [NSString stringWithCString:selectorName
                                                      encoding:NSUTF8StringEncoding];
        
        if ([SelectorNameNS rangeOfString:@"."].location == 0) {  //.cxx.destruct etc
            continue;
        }
        
        for (NSDictionary *dict in propertiesArray) {
            NSString *propertyName = [dict objectForKey:@"name"];
            
            if ([propertyName isEqual:SelectorNameNS]) {
                returnTypeSameAsProperty = [dict objectForKey:@"type"];
                break;
            }
        }
        
        NSString *startSign = isInstanceMethod ? @"-" : @"+";
        
        NSString *startTypes =
        returnTypeSameAsProperty
        ? [NSString stringWithFormat:@"\n%@(%@)", startSign, returnTypeSameAsProperty]
        : [NSString
           stringWithFormat:@"\n%@(%@)", startSign, [self commonTyps:[NSString stringWithCString:returnType
                                                                                        encoding:NSUTF8StringEncoding] inName:nil inIvarList:NO]];
        free(returnType);
        
        returnString = [returnString stringByAppendingString:startTypes];
        
        if (methodArgs > 2) {
            NSArray *selValuesArray = [SelectorNameNS componentsSeparatedByString:@":"];
            
            for (unsigned i = 2; i < methodArgs; i++) {
                char *methodType = method_copyArgumentType(currentMethod, i);
                NSString *methodTypeSameAsProperty = nil;
                
                if (methodArgs == 3) {
                    for (NSDictionary *dict in propertiesArray) {
                        NSString *propertyName = [dict objectForKey:@"name"];
                        NSString *firstCapitalized = [[propertyName substringToIndex:1] capitalizedString];
                        NSString *capitalizedFirst =
                        [firstCapitalized stringByAppendingString:[propertyName substringFromIndex:1]];
                        
                        if ([[selValuesArray objectAtIndex:0]
                             isEqual:[NSString stringWithFormat:@"set%@", capitalizedFirst]]) {
                            methodTypeSameAsProperty = [dict objectForKey:@"type"];
                            break;
                        }
                    }
                }
                
                if (methodTypeSameAsProperty) {
                    if (i == methodArgs - 1) {
                        returnString = [returnString stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d", [selValuesArray objectAtIndex:i - 2], methodTypeSameAsProperty, i - 1]];
                    } else {
                        returnString = [returnString stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d ", [selValuesArray objectAtIndex:i - 2], methodTypeSameAsProperty, i - 1]];
                    }
                } else {
                    id object = [selValuesArray objectAtSafeIndex:i - 2];
                    
                    if (object == nil) {
                        continue;
                    }
                    NSString *methodArgType = [self commonTyps:[NSString stringWithCString:methodType encoding:NSUTF8StringEncoding] inName:nil inIvarList:NO];
                    if (i == methodArgs - 1) {
                        returnString = [returnString stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d", object, methodArgType
                                                                              , i - 1]];
                    } else {
                        returnString = [returnString stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d ", object,
                                                                              methodArgType, i - 1]];
                    }
                }
                
                free(methodType);
            }
        } else {
            returnString = [returnString
                            stringByAppendingString:[NSString stringWithFormat:@"%@", SelectorNameNS]];
        }
        returnString = [returnString stringByAppendingString:@";"];
    }
    
    free(methodsArray);
    
    return returnString;
}

#pragma mark - Getter & Setter

- (NSSet<NSString *> *)forbiddenClasses {
    return self.mutableForbiddenClasses;
}

- (NSSet<NSString *> *)forbiddenPaths {
    return self.mutableForbiddenPaths;
}

- (NSMutableSet<NSString *> *)mutableForbiddenClasses {
    if (_mutableForbiddenClasses == nil) {
        _mutableForbiddenClasses = [NSMutableSet set];
        // UINSServiceViewController requires Marzipan
        [_mutableForbiddenClasses addObject:@"UINSServiceViewController"];
        [_mutableForbiddenClasses addObject:@"AWBAlgorithm"];
    }
    return _mutableForbiddenClasses;
}

- (NSMutableSet<NSString *> *)mutableForbiddenPaths {
    if (_mutableForbiddenPaths == nil) {
        _mutableForbiddenPaths = [NSMutableSet set];
        [_mutableForbiddenPaths addObject:@"libobjc.A.dylib"];
        [_mutableForbiddenPaths addObject:@"libcryptex"];
        [_mutableForbiddenPaths addObject:@"libcrypto"];
        [_mutableForbiddenPaths addObject:@"libssl"];
        
        [_mutableForbiddenPaths addObject:@"/System/Library/Extensions"];
        
        [_mutableForbiddenPaths addObject:@"ActionKit.framework"];
        [_mutableForbiddenPaths addObject:@"ActionKitUI.framework"];
        [_mutableForbiddenPaths addObject:@"WorkflowUI.framework"];
    }
    return _mutableForbiddenPaths;
}


- (NSMutableArray<NSMutableDictionary *> *)allStructsFound {
    if (_allStructsFound == nil) {
        _allStructsFound = [NSMutableArray array];
    }
    return _allStructsFound;
}

- (NSMutableArray<NSString *> *)allImagesProcessed {
    if (_allImagesProcessed == nil) {
        _allImagesProcessed = [NSMutableArray array];
    }
    return _allImagesProcessed;
}

- (NSMutableArray<NSString *> *)classesInStructs {
    if (_classesInStructs == nil) {
        _classesInStructs = [NSMutableArray array];
    }
    return _classesInStructs;
}

- (NSMutableArray<NSString *> *)classesInClass {
    if (_classesInClass == nil) {
        _classesInClass = [NSMutableArray array];
    }
    return _classesInClass;
}

- (NSMutableArray<NSString *> *)processedImages {
    if (_processedImages == nil) {
        _processedImages = [NSMutableArray array];
    }
    return _processedImages;
}

@end
