/*
   classdump-dyld is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   any later version.

   classdump-dyld is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.
 */
/*
   @interface NSCFType : NSObject

   @end

   @interface NSCFType (bro)

   - (NSRange)rangeOfString:(NSString *)brooo;

   @end


   @implementation NSCFType (bro)

   - (NSRange)rangeOfString:(NSString *)broo {

   NSLog(@"range of string: %@", broo);
   return NSMakeRange(0,0);
   }

   @end
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/loader.h>
#import <TargetConditionals.h>
static BOOL inDebug = NO;
static BOOL isIOS11 = NO;
static NSArray *userBlacklisted;

#define CDLog(...) \
    if (inDebug) NSLog(@"classdump-dyld : %@", [NSString stringWithFormat:__VA_ARGS__])
#define SIZE_LIMIT  1300000000

#define RESET       "\033[0m"
#define BOLDWHITE   "\033[1m\033[37m"
#define CLEARSCREEN "\e[1;1H\e[2J"

#include <stdio.h>
#include <dlfcn.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld_images.h>

#define DLog(format, ...) CFShow((__bridge CFStringRef)[NSString stringWithFormat:format, ## __VA_ARGS__]);
#define LOG_FILE_LINE NSLog(@"[%@ at %i]", [[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__);

//#define LOG_FILE_LINE

static BOOL addHeadersFolder = NO;
static BOOL shouldImportStructs = 0;
static NSMutableArray *allStructsFound = nil;
static NSMutableArray *classesInStructs = nil;
static NSMutableArray *classesInClass = nil;
static NSMutableArray *processedImages = nil;
NSString *classID = nil;
NSString *onlyOneClass = nil;

@interface NSArray (extras)
- (id)reversedArray;
@end


const struct dyld_all_image_infos *dyld_all_image_infos;
//extern "C" struct dyld_all_image_infos* _dyld_get_all_image_infos();
NSString * propertyLineGenerator(NSString *attributes, NSString *name);
NSString * commonTypes(NSString *atype, NSString **inName, BOOL inIvarList);




extern "C" int parseImage(char *image, BOOL writeToDisk, NSString *outputDir, BOOL getSymbols, BOOL isRecursive, BOOL buildOriginalDirs, BOOL simpleHeader, BOOL skipAlreadyFound, BOOL skipApplications);

static void list_dir(const char *dir_name, BOOL writeToDisk, NSString *outputDir, BOOL getSymbols, BOOL recursive, BOOL simpleHeader, BOOL skipAlreadyFound, BOOL skipApplications);
static NSMutableArray *allImagesProcessed;
static uint8_t *_cacheData;
static struct cache_header *_cacheHead;
static BOOL shouldDLopen32BitExecutables = NO;


/****** Helper Functions ******/
static NSMutableArray *forbiddenClasses = nil;
NSMutableArray *forbiddenPaths = nil;




struct cache_header {
    char magic[16];                     // e.g. "dyld_v0    i386"
    uint32_t mappingOffset;             // file offset to first dyld_cache_mapping_info
    uint32_t mappingCount;              // number of dyld_cache_mapping_info entries
    uint32_t imagesOffsetOld;           // UNUSED: moved to imagesOffset to prevent older dsc_extarctors from crashing
    uint32_t imagesCountOld;            // UNUSED: moved to imagesCount to prevent older dsc_extarctors from crashing
    uint64_t dyldBaseAddress;           // base address of dyld when cache was built
    uint64_t codeSignatureOffset;       // file offset of code signature blob
    uint64_t codeSignatureSize;         // size of code signature blob (zero means to end of file)
    uint64_t slideInfoOffsetUnused;     // unused.  Used to be file offset of kernel slid info
    uint64_t slideInfoSizeUnused;       // unused.  Used to be size of kernel slid info
    uint64_t localSymbolsOffset;        // file offset of where local symbols are stored
    uint64_t localSymbolsSize;          // size of local symbols information
    uint8_t uuid[16];                   // unique value for each shared cache file
    uint64_t cacheType;                 // 0 for development, 1 for production, 2 for multi-cache
    uint32_t branchPoolsOffset;         // file offset to table of uint64_t pool addresses
    uint32_t branchPoolsCount;          // number of uint64_t entries
    uint64_t dyldInCacheMH;             // (unslid) address of mach_header of dyld in cache
    uint64_t dyldInCacheEntry;          // (unslid) address of entry point (_dyld_start) of dyld in cache
    uint64_t imagesTextOffset;          // file offset to first dyld_cache_image_text_info
    uint64_t imagesTextCount;           // number of dyld_cache_image_text_info entries
    uint64_t patchInfoAddr;             // (unslid) address of dyld_cache_patch_info
    uint64_t patchInfoSize;             // Size of all of the patch information pointed to via the dyld_cache_patch_info
    uint64_t otherImageGroupAddrUnused;       // unused
    uint64_t otherImageGroupSizeUnused;       // unused
    uint64_t progClosuresAddr;          // (unslid) address of list of program launch closures
    uint64_t progClosuresSize;          // size of list of program launch closures
    uint64_t progClosuresTrieAddr;      // (unslid) address of trie of indexes into program launch closures
    uint64_t progClosuresTrieSize;      // size of trie of indexes into program launch closures
    uint32_t platform;                  // platform number (macOS=1, etc)
    uint32_t formatVersion          : 8,     // dyld3::closure::kFormatVersion
             dylibsExpectedOnDisk   : 1,// dyld should expect the dylib exists on disk and to compare inode/mtime to see if cache is valid
             simulator              : 1,// for simulator of specified platform
             locallyBuiltCache      : 1,// 0 for B&I built cache, 1 for locally built cache
             builtFromChainedFixups : 1, // some dylib in cache was built using chained fixups, so patch tables must be used for overrides
             padding                : 20;// TBD
    uint64_t sharedRegionStart;         // base load address of cache if not slid
    uint64_t sharedRegionSize;          // overall size required to map the cache and all subCaches, if any
    uint64_t maxSlide;                  // runtime slide of cache can be between zero and this value
    uint64_t dylibsImageArrayAddr;      // (unslid) address of ImageArray for dylibs in this cache
    uint64_t dylibsImageArraySize;      // size of ImageArray for dylibs in this cache
    uint64_t dylibsTrieAddr;            // (unslid) address of trie of indexes of all cached dylibs
    uint64_t dylibsTrieSize;            // size of trie of cached dylib paths
    uint64_t otherImageArrayAddr;       // (unslid) address of ImageArray for dylibs and bundles with dlopen closures
    uint64_t otherImageArraySize;       // size of ImageArray for dylibs and bundles with dlopen closures
    uint64_t otherTrieAddr;             // (unslid) address of trie of indexes of all dylibs and bundles with dlopen closures
    uint64_t otherTrieSize;             // size of trie of dylibs and bundles with dlopen closures
    uint32_t mappingWithSlideOffset;    // file offset to first dyld_cache_mapping_and_slide_info
    uint32_t mappingWithSlideCount;     // number of dyld_cache_mapping_and_slide_info entries
    uint64_t dylibsPBLStateArrayAddrUnused;       // unused
    uint64_t dylibsPBLSetAddr;          // (unslid) address of PrebuiltLoaderSet of all cached dylibs
    uint64_t programsPBLSetPoolAddr;    // (unslid) address of pool of PrebuiltLoaderSet for each program
    uint64_t programsPBLSetPoolSize;    // size of pool of PrebuiltLoaderSet for each program
    uint64_t programTrieAddr;           // (unslid) address of trie mapping program path to PrebuiltLoaderSet
    uint32_t programTrieSize;
    uint32_t osVersion;                 // OS Version of dylibs in this cache for the main platform
    uint32_t altPlatform;               // e.g. iOSMac on macOS
    uint32_t altOsVersion;              // e.g. 14.0 for iOSMac
    uint64_t swiftOptsOffset;           // VM offset from cache_header* to Swift optimizations header
    uint64_t swiftOptsSize;             // size of Swift optimizations header
    uint32_t subCacheArrayOffset;       // file offset to first dyld_subcache_entry
    uint32_t subCacheArrayCount;        // number of subCache entries
    uint8_t symbolFileUUID[16];         // unique value for the shared cache file containing unmapped local symbols
    uint64_t rosettaReadOnlyAddr;       // (unslid) address of the start of where Rosetta can add read-only/executable data
    uint64_t rosettaReadOnlySize;       // maximum size of the Rosetta read-only/executable region
    uint64_t rosettaReadWriteAddr;      // (unslid) address of the start of where Rosetta can add read-write data
    uint64_t rosettaReadWriteSize;      // maximum size of the Rosetta read-write region
    uint32_t imagesOffset;              // file offset to first dyld_cache_image_info
    uint32_t imagesCount;               // number of dyld_cache_image_info entries
    uint32_t cacheSubType;              // 0 for development, 1 for production, when cacheType is multi-cache(2)
    uint64_t objcOptsOffset;            // VM offset from cache_header* to ObjC optimizations header
    uint64_t objcOptsSize;              // size of ObjC optimizations header
    uint64_t cacheAtlasOffset;          // VM offset from cache_header* to embedded cache atlas for process introspection
    uint64_t cacheAtlasSize;            // size of embedded cache atlas
    uint64_t dynamicDataOffset;         // VM offset from cache_header* to the location of dyld_cache_dynamic_data_header
    uint64_t dynamicDataMaxSize;        // maximum size of space reserved from dynamic data
};


BOOL isMachOExecutable(const char *image) {
    FILE *machoFile = fopen(image, "rb");

    if (machoFile == 0) {
        return NO;
    }

    //#ifdef __LP64__
    mach_header_64 machHeader;
    //#else
    //mach_header machHeader;
    //#endif

    int n = fread(&machHeader, sizeof(machHeader), 1, machoFile);

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

    mach_header_64 machHeader;
    int n = fread(&machHeader, sizeof(machHeader), 1, machoFile);

    if (n != 1) {
        fclose(machoFile);
        return NO;
    }

    BOOL is64 = machHeader.magic != MH_MAGIC; // instead of ==MH_MAGIC_64
    fclose(machoFile);
    return is64;
}

BOOL fileExistsOnDisk(const char *image) {
    FILE *aFile = fopen(image, "r");
    BOOL exists = aFile != 0;

    fclose(aFile);
    return exists;
}

BOOL arch64() {
    //size_t size;
    //sysctlbyname("hw.cpu64bit_capable", NULL, &size, NULL, 0);
    //BOOL cpu64bit;
    //sysctlbyname("hw.cpu64bit_capable", &cpu64bit, &size, NULL, 0);
    //return cpu64bit;

#ifdef __LP64__
    return YES;

#endif
    return NO;
}

static BOOL priorToiOS7() {
    return ![objc_getClass("NSProcessInfo") instancesRespondToSelector:@selector(endActivity:)];
}

NSMutableArray * generateForbiddenClassesArray(BOOL isRecursive) {
    BOOL IOS11 = [[[NSProcessInfo processInfo] operatingSystemVersionString] rangeOfString:@"Version 11"].location == 0;
    BOOL IOS12 = [[[NSProcessInfo processInfo] operatingSystemVersionString] rangeOfString:@"Version 12"].location == 0;

    forbiddenClasses = [[NSMutableArray alloc] init];
    return forbiddenClasses;

    if (priorToiOS7()) {
        [forbiddenClasses addObject:@"VKRoadGroup"];
        [forbiddenClasses addObject:@"SBApplication"];
        [forbiddenClasses addObject:@"SBSMSApplication"];
        [forbiddenClasses addObject:@"SBFakeNewsstandApplication"];
        [forbiddenClasses addObject:@"SBWebApplication"];
        [forbiddenClasses addObject:@"SBNewsstandApplication"];
    }

    if (isRecursive) {
        [forbiddenClasses addObject:@"UIScreen"];
        [forbiddenClasses addObject:@"UICollectionViewData"];
    }

    //iWork related crashing classes
    [forbiddenClasses addObject:@"KNSlideStyle"];
    [forbiddenClasses addObject:@"TSWPListStyle"];
    [forbiddenClasses addObject:@"TSWPColumnStyle"];
    [forbiddenClasses addObject:@"TSWPCharacterStyle"];
    [forbiddenClasses addObject:@"TSWPParagraphStyle"];
    [forbiddenClasses addObject:@"TSTTableStyle"];
    [forbiddenClasses addObject:@"TSTCellStyle"];
    [forbiddenClasses addObject:@"TSDMediaStyle"];
    [forbiddenClasses addObject:@"TSDShapeStyle"];
    [forbiddenClasses addObject:@"TSCHStylePasteboardData"];
    [forbiddenClasses addObject:@"OABShapeBaseManager"];
    [forbiddenClasses addObject:@"TSCH3DGLRenderProcessor"];
    [forbiddenClasses addObject:@"TSCH3DAnimationTimeSlice"];
    [forbiddenClasses addObject:@"TSCH3DBarChartDefaultAppearance"];
    [forbiddenClasses addObject:@"TSCH3DGenericAxisLabelPositioner"];
    [forbiddenClasses addObject:@"TSCHChartSeriesNonStyle"];
    [forbiddenClasses addObject:@"TSCHChartAxisNonStyle"];
    [forbiddenClasses addObject:@"TSCHLegendNonStyle"];
    [forbiddenClasses addObject:@"TSCHChartNonStyle"];
    [forbiddenClasses addObject:@"TSCHChartSeriesStyle"];
    [forbiddenClasses addObject:@"TSCHChartAxisStyle"];
    [forbiddenClasses addObject:@"TSCHLegendStyle"];
    [forbiddenClasses addObject:@"TSCHChartStyle"];
    [forbiddenClasses addObject:@"TSCHBaseStyle"];

    //other classes that crash on opening outside their process
    [forbiddenClasses addObject:@"LineServiceManager"];
    [forbiddenClasses addObject:@"GKBubbleFlowBubbleControl"];
    [forbiddenClasses addObject:@"AXBackBoardGlue"];
    [forbiddenClasses addObject:@"TMBackgroundTaskAgent"];
    [forbiddenClasses addObject:@"PLWallpaperAssetAccessibility"];
    [forbiddenClasses addObject:@"MPMusicPlayerController"];
    [forbiddenClasses addObject:@"PUAlbumListCellContentView"];
    [forbiddenClasses addObject:@"SBAXItemChooserTableViewCell"];
    [forbiddenClasses addObject:@"WebPreferences"];
    [forbiddenClasses addObject:@"WebFrameView"];
    [forbiddenClasses addObject:@"VMServiceClient"];
    [forbiddenClasses addObject:@"VKClassicGlobeCanvas"];
    [forbiddenClasses addObject:@"VKLabelModel"];
    [forbiddenClasses addObject:@"UICTFont"];
    [forbiddenClasses addObject:@"UIFont"];
    [forbiddenClasses addObject:@"NSFont"];
    [forbiddenClasses addObject:@"PLImageView"];
    [forbiddenClasses addObject:@"PLPolaroidImageView"];
    [forbiddenClasses addObject:@"MFSMTPConnection"];
    [forbiddenClasses addObject:@"MFConnection"];
    [forbiddenClasses addObject:@"AXSpringBoardSettingsLoader"];
    [forbiddenClasses addObject:@"AXUIActiveWindow"];
    [forbiddenClasses addObject:@"VolumeListener"];
    [forbiddenClasses addObject:@"VKTransitLineMarker"];
    [forbiddenClasses addObject:@"VKLabelMarkerShield"];
    [forbiddenClasses addObject:@"VKImageSourceKey"];
    [forbiddenClasses addObject:@"MMSDK"];
    [forbiddenClasses addObject:@"MDLAsset"];
    [forbiddenClasses addObject:@"MDLCamera"];
    [forbiddenClasses addObject:@"SCNMetalResourceManager"];
    [forbiddenClasses addObject:@"SCNRenderContextImp"];
    [forbiddenClasses addObject:@"SUICFlamesView"];
    [forbiddenClasses addObject:@"WAMediaPickerAsset"];
    [forbiddenClasses addObject:@"FBSDKAppLinkResolver"];
    [forbiddenClasses addObject:@"BFTaskCompletionSource"];
    [forbiddenClasses addObject:@"FilterContext"];
    [forbiddenClasses addObject:@"GMSZoomTable"];
    [forbiddenClasses addObject:@"CardIOCardScanner"];
    [forbiddenClasses addObject:@"LineServiceManager"];
    [forbiddenClasses addObject:@"WAServerProperties"];
    [forbiddenClasses addObject:@"FBGroupPendingStream"];
    [forbiddenClasses addObject:@"FBConsoleGetTagStatuses_result"];
    [forbiddenClasses addObject:@"CLLocationProviderAdapter"];
    [forbiddenClasses addObject:@"AXBackBoardGlue"];
    [forbiddenClasses addObject:@"TMBackgroundTaskAgent"];
    [forbiddenClasses addObject:@"TSCHReferenceLineNonStyle"];
    [forbiddenClasses addObject:@"TSTTableInfo"];
    [forbiddenClasses addObject:@"TSCHReferenceLineStyle"];
    [forbiddenClasses addObject:@"AZSharedUserDefaults"];
    [forbiddenClasses addObject:@"NSLeafProxy"];
    [forbiddenClasses addObject:@"FigIrisAutoTrimmerMotionSampleExport"];
    [forbiddenClasses addObject:@"RCDebugRecordingController"];
    [forbiddenClasses addObject:@"CoreKnowledge.CKInMemoryKnowledgeStorage"];
    [forbiddenClasses addObject:@"CoreKnowledge.CKUserDefaultsKnowledgeStorage"];
    [forbiddenClasses addObject:@"CoreKnowledge.CKSQLKnowledgeStorage"];
    [forbiddenClasses addObject:@"CoreKnowledge.CKEntity"];
    [forbiddenClasses addObject:@"CoreKnowledge.CKKnowledgeStore"];
    [forbiddenClasses addObject:@"JSExport"];
    [forbiddenClasses addObject:@"SBClockApplicationIconImageView"];
    [forbiddenClasses addObject:@"CMFallStatsItemsIterator"];
    [forbiddenClasses addObject:@"HFEmptyLocalizableStringKey"];
    [forbiddenClasses addObject:@"OZFxPlugHostPrivateAPI"];
    [forbiddenClasses addObject:@"MovieController"];
    [forbiddenClasses addObject:@"_TtC7SwiftUIP33_936A47782A7E2FBE97D58CDBAEB0277015ProgressWrapper"];
    [forbiddenClasses addObject:@"HFHumidityStatusItem"];
    [forbiddenClasses addObject:@"HFDemoModeAccessory"];

    if (IOS11 || IOS12) {
        [forbiddenClasses addObject:@"SKTransformNode"];
        [forbiddenClasses addObject:@"OZFxPlugParameterHandler"];
        [forbiddenClasses addObject:@"OZFxPlugParameterHandler_v4"];
        [forbiddenClasses addObject:@"PAETransitionDefaultBase"];
        [forbiddenClasses addObject:@"PAEGeneratorDefaultBase"];
        [forbiddenClasses addObject:@"PAEFilterDefaultBase"];
        [forbiddenClasses addObject:@"MTLToolsDevice"];
        [forbiddenClasses addObject:@"CMMTLDevice"];
        [forbiddenClasses addObject:@"SBReachabilityManager"];
        [forbiddenClasses addObject:@"IGRTCBroadcastSession"];
        [forbiddenClasses addObject:@"FBVideoBroadcastSwitchableSession"];
        [forbiddenClasses addObject:@"FBVideoBroadcastSessionBase"];
        [forbiddenClasses addObject:@"NFSecureElementWrapper"];

        [forbiddenClasses addObject:@"JTImageView"];
        [forbiddenClasses addObject:@"PNPWizardScratchpadInkView"];
        [forbiddenClasses addObject:@"PFMulticasterDistributionMethods"];
        [forbiddenClasses addObject:@"PFEmbeddedMulticasterImplementation"];
        [forbiddenClasses addObject:@"AAJSON"];
    }

    return forbiddenClasses;
}

static NSString * copyrightMessage(char *image) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool  alloc] init];
    NSString *version = [NSProcessInfo processInfo ].operatingSystemVersionString;
    NSLocale *loc = [NSLocale localeWithLocaleIdentifier:@"en-us"];
    NSString *date = [NSDate.date descriptionWithLocale:loc];

    NSString *message = [[NSString alloc] initWithFormat:@"/*\n\
                       * This header is generated by classdump-dyld 1.6\n\
                       * on %@\n\
                       * Operating System: %@\n\
                       * Image Source: %s\n\
                       * classdump-dyld is licensed under GPLv3, Copyright \u00A9 2013-2016 by Elias Limneos. Updated by Kevin Bradley.\n\
                       */\n\n", date, version, image];

    [pool drain];

    return message;
}

void printHelp() {
    printf("\nclassdump-dyld v1.6. Licensed under GPLv3, Copyright \u00A9 2013-2014 by Elias Limneos. Updated by Kevin Bradley.\n\n");
    printf("Usage: classdump-dyld [<options>] <filename|framework>\n");
    printf("       or\n");
    printf("       classdump-dyld [<options>] -r <sourcePath>\n\n");

    printf("Options:\n\n");


    printf("    Structure:\n");
    printf("        -g   Generate symbol names file\n");
    printf("        -b   Build original directory structure in output dir\n");
    printf("        -h   Add a \"Headers\" directory to place headers in\n");
    printf("        -u   Do not include framework when importing headers (\"Header.h\" instead of <frameworkName/Header.h>)\n\n");

    printf("    Output:\n");
    printf("        -o   <outputdir> Save generated headers to defined path\n\n");

    printf("    Mass dumping: (requires -o)\n");
    printf("        -c   Dump all images found in dyld_shared_cache\n");
    printf("        -r   <sourcepath> Recursively dump any compatible Mach-O file found in the given path\n");
    printf("        -s   In a recursive dump, skip header files already found in the same output directory\n\n");

    printf("    Single Class:\n");
    printf("        -j   <className> Dump only the specified class name. (Does not work with -c or -r )\n");
    printf("                         This might also dump additional imported or required headers.\n\n");

    printf("    Miscellaneous\n");
    printf("        -D   Enable debug printing for troubleshooting errors\n");
    printf("        -e   dpopen 32Bit executables instead of injecting them (iOS 5+, use if defaults fail.This will skip any 64bit executable) \n");
    printf("        -a   In a recursive dump, include 'Applications' directories (skipped by default) \n");
    printf("        -B   <sourcepath> a text file that includes line delimited list of frameworks to skip\n\n");

    printf("    Examples:\n");
    printf("        Example 1: classdump-dyld -o outdir /System/Library/Frameworks/UIKit.framework\n");
    printf("        Example 2: classdump-dyld -o outdir /usr/libexec/backboardd\n");
    printf("        Example 3 (recursive): classdump-dyld -o outdir -c  (Dumps all files residing in dyld_shared_cache)\n");
    printf("        Example 4 (recursive): classdump-dyld -o outdir -r /System/Library/\n");
    printf("        Example 5 (recursive): classdump-dyld -o outdir -r / -c  (Mass-dumps almost everything on device)\n\n");
}

static NSString * print_free_memory() {
    mach_port_t host_port;
    mach_msg_type_number_t host_size;
    vm_size_t pagesize;

    host_port = mach_host_self();
    host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
    host_page_size(host_port, &pagesize);

    vm_statistics_data_t vm_stat;

    if (host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size) != KERN_SUCCESS) {
        //Failed to fetch vm stats
    }

    natural_t mem_free = vm_stat.free_count * pagesize;

    if (mem_free < 10000000) { // break if less than 10MB of RAM
        printf("Error: Out of memory. You can repeat with -s option to continue from where left.\n\n");
        exit(0);
    }

    if (mem_free < 20000000) { // warn if less than 20MB of RAM
        return [NSString stringWithFormat:@"Low Memory: %u MB free. Might exit to prevent system hang", (mem_free / 1024 / 1024)];
    } else {
        return [NSString stringWithCString:"" encoding:NSASCIIStringEncoding];
        //return [NSString stringWithFormat:@"Memory: %u MB free",(mem_free/1024/1024)] ;
    }
}

// A nice loading bar. Credits: http://www.rosshemsley.co.uk/2011/02/creating-a-progress-bar-in-c-or-any-other-console-app/
static inline void loadBar(int x, int n, int r, int w, const char *className) {
    //    return;
    // Only update r times.
    if ((n / r) < 1) {
        return;
    }

    if (x % (n / r) != 0) {
        return;
    }

    // Calculuate the ratio of complete-to-incomplete.
    float ratio = x / (float)n;
    int c = ratio * w;

    // Show the percentage complete.
    printf("%3d%% [", (int)(ratio * 100) );

    // Show the load bar.
    for (int x = 0; x < c; x++) {
        printf("=");
    }

    for (int x = c; x < w; x++) {
        printf(" ");
    }

    // ANSI Control codes to go back to the
    // previous line and clear it.
    printf("] %s %d/%d <%s>\n\033[F\033[J", [print_free_memory() UTF8String], x, n, className);
}

NSMutableArray * generateForbiddenPathsArray(BOOL isRecursive) {
    forbiddenPaths = [[NSMutableArray alloc] init];
    // The following paths are skipped for known issues that arise when their symbols are added to the flat namespace

    [forbiddenPaths addObject:@"/usr/bin"];
    [forbiddenPaths addObject:@"/Developer"];
    [forbiddenPaths addObject:@"/Library/Switches"];
    [forbiddenPaths addObject:@"SBSettings"];
    [forbiddenPaths addObject:@"Activator"];
    [forbiddenPaths addObject:@"launchd"];

    if (priorToiOS7()) {
        [forbiddenPaths addObject:@"/System/Library/Frameworks/PassKit.framework/passd"];
    }

    [forbiddenPaths addObject:@"AGXMetal"];

    /*
       [forbiddenPaths addObject:@"PhotosUI"];

       //[forbiddenPaths addObject:@"AccessibilityUIService"];
       [forbiddenPaths addObject:@"CoreSuggestionsInternals"];
       [forbiddenPaths addObject:@"GameCenterPrivateUI"];
       [forbiddenPaths addObject:@"GameCenterUI"];
       [forbiddenPaths addObject:@"LegacyGameKit"];
       [forbiddenPaths addObject:@"IMAP.framework"];
       [forbiddenPaths addObject:@"POP.framework"];
       [forbiddenPaths addObject:@"Vision.framework"];
       [forbiddenPaths addObject:@"Celestial.framework"];
       [forbiddenPaths addObject:@"SpriteKit.framework"];
       [forbiddenPaths addObject:@"PodcastsKit.framework"];

       [forbiddenPaths addObject:@"SiriUICore.framework"];
       [forbiddenPaths addObject:@"CoreKnowledge.framework"];
       [forbiddenPaths addObject:@"ProVideo.framework"];
       [forbiddenPaths addObject:@"Memories.framework"];
       [forbiddenPaths addObject:@"MetalTools.framework"];
       [forbiddenPaths addObject:@"SwiftUI.framework"];
       [forbiddenPaths addObject:@"AppStoreKit.framework"];
       [forbiddenPaths addObject:@"AppleMediaServicesUIDynamic.framework"];
       [forbiddenPaths addObject:@"CMCapture.framework"];
       [forbiddenPaths addObject:@"CloudKitCode.framework"];
       [forbiddenPaths addObject:@"FMClient.framework"];
       [forbiddenPaths addObject:@"Parsec"];
       [forbiddenPaths addObject:@"ZoomTouch"];
       [forbiddenPaths addObject:@"VisualVoicemailUsage"];
     */
    if (isRecursive) {
        [forbiddenPaths addObject:@"braille"];
        [forbiddenPaths addObject:@"QuickSpeak"];
        [forbiddenPaths addObject:@"HearingAidUIServer"];
        [forbiddenPaths addObject:@"Mail.siriUIBundle"];
        [forbiddenPaths addObject:@"TTSPlugins"];
    }

    [forbiddenPaths addObject:@"Home.framework"];
    [forbiddenPaths addObject:@"AppPredictionInternal.framework"];
    [forbiddenPaths addObject:@"NumbersQuicklook.framework"];
    [forbiddenPaths addObject:@"TSText.framework"];
    return forbiddenPaths;
}

int locationOfString(const char *haystack, const char *needle) {
    const char *found = strstr(haystack, needle);
    int anIndex = -1;

    if (found != NULL) {
        anIndex = found - haystack;
    }

    return anIndex;
}

/****** Parsing Functions ******/
@implementation NSMethodSignature (classdump_dyld_helper)

+ (id)cd_signatureWithObjCTypes:(const char *)types {
    //LOG_FILE_LINE;
    __block NSString *text = [NSString stringWithCString:types encoding:NSUTF8StringEncoding];

    while ([text rangeOfString:@"("].location != NSNotFound) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\(([^\\(\\)]+)\\)" options:0 error:nil];

        // test if the anticipated union (embraced in parentheseis) is actually a function definition rather than a union

        NSRange range = [text rangeOfString:@"\\(([^\\(\\)]+)\\)" options:NSRegularExpressionSearch];
        NSString *rep = [text substringWithRange:range];
        NSString *testUnion = [rep stringByReplacingOccurrencesOfString:@"(" withString:@"{"]; //just to test if it internally passes as a masqueraded struct
        testUnion = [testUnion stringByReplacingOccurrencesOfString:@")" withString:@"}"];

        if ([testUnion rangeOfString:@"="].location == NSNotFound) {
            // its a function!
            text = [text stringByReplacingOccurrencesOfString:@"(" withString:@"__FUNCTION_START__"];
            text = [text stringByReplacingOccurrencesOfString:@")" withString:@"__FUNCTION_END__"];
            continue;
        }

        [regex enumerateMatchesInString:text options:0
                                  range:NSMakeRange(0, [text length])
                             usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
        {
            for (int i = 1; i < [result numberOfRanges]; i++) {
                NSString *textFound = [text substringWithRange:[result rangeAtIndex:i]];
                text = [text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"(%@)", textFound] withString:[NSString stringWithFormat:@"{union={%@}ficificifloc}", textFound]]; //add an impossible match of types
                *stop = YES;
            }
        }];
    }

    if ([text rangeOfString:@"{"].location != NSNotFound) {
        BOOL FOUND = 1;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?<!\\^)\\{([^\\{^\\}]+)\\}" options:0 error:nil];

        while (FOUND) {
            NSRange range = [regex rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0, [text length])];

            if (range.location != NSNotFound) {
                FOUND = 1;
                NSString *result = [text substringWithRange:range];
                text = [text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@", result] withString:[NSString stringWithFormat:@"^^^%@", result]];
            } else {
                FOUND = 0;
            }
        }

        FOUND = 1;
        regex = [NSRegularExpression regularExpressionWithPattern:@"(?<!\\^)\\{([^\\}]+)\\}" options:0 error:nil];

        while (FOUND) {
            NSRange range = [regex rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0, [text length])];

            if (range.location != NSNotFound) {
                FOUND = 1;
                NSString *result = [text substringWithRange:range];
                text = [text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@", result] withString:[NSString stringWithFormat:@"^^^%@", result]];
            } else {
                FOUND = 0;
            }
        }
    }

    text = [text stringByReplacingOccurrencesOfString:@"__FUNCTION_START__" withString:@"("];
    text = [text stringByReplacingOccurrencesOfString:@"__FUNCTION_END__" withString:@")"];

    types = [text UTF8String];

    return [self signatureWithObjCTypes:types];
}

- (const char *)cd_getArgumentTypeAtIndex:(int)anIndex {
    const char *argument = [self getArgumentTypeAtIndex:anIndex];
    //LOG_FILE_LINE;
    NSString *char_ns = [NSString stringWithCString:argument encoding:NSUTF8StringEncoding];
    __block NSString *text = char_ns;

    if ([text rangeOfString:@"^^^"].location != NSNotFound) {
        text = [text stringByReplacingOccurrencesOfString:@"^^^" withString:@""];
    }

    while ([text rangeOfString:@"{union"].location != NSNotFound) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\{union.+?ficificifloc\\})" options:0 error:nil];
        [regex enumerateMatchesInString:text options:0
                                  range:NSMakeRange(0, [text length])
                             usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
        {
            for (int i = 1; i < [result numberOfRanges]; i++) {
                NSString *textFound = [text substringWithRange:[result rangeAtIndex:i]];
                NSString *textToPut = [textFound substringFromIndex:8];
                NSInteger weirdIndex = textToPut.length - 1 - (@"ficificifloc".length + 1);

                //NSLog(@"weirdIndex: %lu lenght:%lu", weirdIndex, textToPut.length);
                if (weirdIndex < textToPut.length) {
                    textToPut = [textToPut substringToIndex:weirdIndex];
                //NSLog(@"textToPut: %@", textToPut);
                }

                text = [text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@", textFound] withString:[NSString stringWithFormat:@"(%@)", textToPut]];
                //NSLog(@"text: %@", text);
                *stop = YES;
            }
        }];
    }

    char_ns = text;
    return [char_ns UTF8String];
}

@end



/****** String Parsing Functions ******/


/****** Properties Parser ******/

NSString * propertyLineGenerator(NSString *attributes, NSString *name) {
    NSCharacterSet *parSet = [NSCharacterSet characterSetWithCharactersInString:@"()"];

    attributes = [attributes stringByTrimmingCharactersInSet:parSet];
    NSMutableArray *attrArr = (NSMutableArray *)[attributes componentsSeparatedByString:@","];
    NSString *type = [attrArr objectAtIndex:0];

    type = [type stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:@""];

    if ([type rangeOfString:@"@"].location == 0 && [type rangeOfString:@"\""].location != NSNotFound) { //E.G. @"NSTimer"
        type = [type stringByReplacingOccurrencesOfString:@"\"" withString:@""];
        type = [type stringByReplacingOccurrencesOfString:@"@" withString:@""];
        type = [type stringByAppendingString:@" *"];
        NSString *classFoundInProperties = [type stringByReplacingOccurrencesOfString:@" *" withString:@""];

        if (![classesInClass containsObject:classFoundInProperties] && [classFoundInProperties rangeOfString:@"<"].location == NSNotFound) {
            [classesInClass addObject:classFoundInProperties];
        }

        if ([type rangeOfString:@"<"].location != NSNotFound) {
            type = [type stringByReplacingOccurrencesOfString:@"> *" withString:@">"];

            if ([type rangeOfString:@"<"].location == 0) {
                type = [@"id" stringByAppendingString:type];
            } else {
                type = [type stringByReplacingOccurrencesOfString:@"<" withString:@"*<"];
            }
        }
    } else if ([type rangeOfString:@"@"].location == 0 && [type rangeOfString:@"\""].location == NSNotFound) {
        type = @"id";
    } else {
        type = commonTypes(type, &name, NO);
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

    for (NSString *attr in attrArr) {
        NSString *vToClear = nil;

        if ([attr rangeOfString:@"V_"].location == 0) {
            vToClear = attr;
            attr = [attr stringByReplacingCharactersInRange:NSMakeRange(0, 2) withString:@""];
            synthesize = [NSString stringWithFormat:@"\t\t\t\t//@synthesize %@=_%@ - In the implementation block", attr, attr];
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
                translatedProperty = @"retain";
            }

            if ([attr isEqual:@"N"]) {
                translatedProperty = @"nonatomic";
            }

            //if ([attr isEqual:@"D"]){ translatedProperty = @"@dynamic"; }
            if ([attr isEqual:@"D"]) {
                continue;
            }

            if ([attr isEqual:@"W"]) {
                translatedProperty = @"__weak";
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

    if ([newPropsArray containsObject:@"nonatomic"] && ![newPropsArray containsObject:@"assign"] && ![newPropsArray containsObject:@"readonly"] && ![newPropsArray containsObject:@"copy"] && ![newPropsArray containsObject:@"retain"]) {
        [newPropsArray addObject:@"assign"];
    }

    newPropsArray = [newPropsArray reversedArray];

    NSString *rebuiltString = [newPropsArray componentsJoinedByString:@","];
    NSString *attrString = [newPropsArray count] > 0 ? [NSString stringWithFormat:@"(%@)", rebuiltString] : @"(assign)";


    return [[NSString alloc] initWithFormat:@"\n%@%@ %@ %@; %@", @"@property ", attrString, type, name, synthesize];
}

/****** Properties Combined Array (for fixing non-matching types)   ******/

static NSMutableArray * propertiesArrayFromString(NSString *propertiesString) {
    NSMutableArray *propertiesExploded = [[propertiesString componentsSeparatedByString:@"\n"] mutableCopy];
    NSMutableArray *typesAndNamesArray = [NSMutableArray array];

    for (NSString *string in propertiesExploded) {
        if (string.length < 1) {
            continue;
        }

        int startlocation = [string rangeOfString:@")"].location;
        int endlocation = [string rangeOfString:@";"].location;

        if ([string rangeOfString:@";"].location == NSNotFound || [string rangeOfString:@")"].location == NSNotFound) {
            continue;
        }

        NSString *propertyTypeFound = [string substringWithRange:NSMakeRange(startlocation + 1, endlocation - startlocation - 1)];
        int firstSpaceLocationBackwards = [propertyTypeFound rangeOfString:@" " options:NSBackwardsSearch].location;

        if ([propertyTypeFound rangeOfString:@" " options:NSBackwardsSearch].location == NSNotFound) {
            continue;
        }

        NSMutableDictionary *typesAndNames = [NSMutableDictionary dictionary];

        NSString *propertyNameFound = [propertyTypeFound substringFromIndex:firstSpaceLocationBackwards + 1];
        propertyTypeFound = [propertyTypeFound substringToIndex:firstSpaceLocationBackwards];

        //propertyTypeFound=[propertyTypeFound stringByReplacingOccurrencesOfString:@" " withString:@""];
        if ([propertyTypeFound rangeOfString:@" "].location == 0) {
            propertyTypeFound = [propertyTypeFound substringFromIndex:1];
        }

        propertyNameFound = [propertyNameFound stringByReplacingOccurrencesOfString:@" " withString:@""];

        [typesAndNames setObject:propertyTypeFound forKey:@"type"];
        [typesAndNames setObject:propertyNameFound forKey:@"name"];
        [typesAndNamesArray addObject:typesAndNames];
    }

    [propertiesExploded release];
    return typesAndNamesArray;
}

/****** Protocol Parser ******/

NSString * buildProtocolFile(Protocol *currentProtocol) {
    NSMutableString *protocolsMethodsString = [[NSMutableString alloc] init];
    //LOG_FILE_LINE;
    NSString *protocolName = [NSString stringWithCString:protocol_getName(currentProtocol) encoding:NSUTF8StringEncoding];

    [protocolsMethodsString appendString:[NSString stringWithFormat:@"\n@protocol %@", protocolName]];
    NSMutableArray *classesInProtocol = [[NSMutableArray alloc] init];

    unsigned int outCount = 0;
    Protocol **protList = protocol_copyProtocolList(currentProtocol, &outCount);

    if (outCount > 0) {
        [protocolsMethodsString appendString:@" <"];
    }

    for (int p = 0; p < outCount; p++) {
        NSString *end = p == outCount - 1 ? [@"" retain] : [@"," retain];
        [protocolsMethodsString appendString:[NSString stringWithFormat:@"%s%@", protocol_getName(protList[p]), end]];
        [end release];
    }

    if (outCount > 0) {
        [protocolsMethodsString appendString:@">"];
    }

    free(protList);

    NSMutableString *protPropertiesString = [[NSMutableString alloc] init];
    unsigned int protPropertiesCount;

    objc_property_t *protPropertyList = protocol_copyPropertyList(currentProtocol, &protPropertiesCount);

    for (int xi = 0; xi < protPropertiesCount; xi++) {
        const char *propname = property_getName(protPropertyList[xi]);
        const char *attrs = property_getAttributes(protPropertyList[xi]);

        //LOG_FILE_LINE;
        NSCharacterSet *parSet = [NSCharacterSet characterSetWithCharactersInString:@"()"];
        NSString *attributes = [[NSString stringWithCString:attrs encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:parSet];
        NSMutableArray *attrArr = (NSMutableArray *)[attributes componentsSeparatedByString:@","];
        NSString *type = [attrArr objectAtIndex:0];

        type = [type stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:@""];

        if ([type rangeOfString:@"@"].location == 0 && [type rangeOfString:@"\""].location != NSNotFound) { //E.G. @"NSTimer"
            type = [type stringByReplacingOccurrencesOfString:@"\"" withString:@""];
            type = [type stringByReplacingOccurrencesOfString:@"@" withString:@""];
            type = [type stringByAppendingString:@" *"];
            NSString *classFoundInProperties = [type stringByReplacingOccurrencesOfString:@" *" withString:@""];

            if (![classesInProtocol containsObject:classFoundInProperties] && [classFoundInProperties rangeOfString:@"<"].location == NSNotFound) {
                [classesInProtocol addObject:classFoundInProperties];
            }
        }

        //LOG_FILE_LINE;
        NSString *newString = propertyLineGenerator([NSString stringWithCString:attrs encoding:NSUTF8StringEncoding], [NSString stringWithCString:propname encoding:NSUTF8StringEncoding]);

        if ([protPropertiesString rangeOfString:newString].location == NSNotFound) {
            [protPropertiesString appendString:newString];
        }

        [newString release];
    }

    [protocolsMethodsString appendString:protPropertiesString];

    free(protPropertyList);

    for (int acase = 0; acase < 4; acase++) {
        unsigned int protocolMethodsCount = 0;
        BOOL isRequiredMethod = acase < 2 ? NO : YES;
        BOOL isInstanceMethod = (acase == 0 || acase == 2) ? NO : YES;

        objc_method_description *protMeths = protocol_copyMethodDescriptionList(currentProtocol, isRequiredMethod, isInstanceMethod, &protocolMethodsCount);

        for (unsigned gg = 0; gg < protocolMethodsCount; gg++) {
            if (acase < 2 && [protocolsMethodsString rangeOfString:@"@optional"].location == NSNotFound) {
                [protocolsMethodsString appendString:@"\n@optional\n"];
            }

            if (acase > 1 && [protocolsMethodsString rangeOfString:@"@required"].location == NSNotFound) {
                [protocolsMethodsString appendString:@"\n@required\n"];
            }

            NSString *startSign = isInstanceMethod == NO ? @"+" : @"-";
            objc_method_description selectorsAndTypes = protMeths[gg];
            SEL selector = selectorsAndTypes.name;
            char *types = selectorsAndTypes.types;
            NSString *protSelector = NSStringFromSelector(selector);
            NSString *finString = @"";
            //CDLog(@"\t\t\t\tAbout to call cd_signatureWithObjCTypes of current protocol with types: %s",types);
            NSMethodSignature *signature = [NSMethodSignature cd_signatureWithObjCTypes:types];
            //CDLog(@"\t\t\t\tGot cd_signatureWithObjCTypes of current protocol");
            //LOG_FILE_LINE;
            NSString *returnType = commonTypes([NSString stringWithCString:[signature methodReturnType] encoding:NSUTF8StringEncoding], nil, NO);

            NSArray *selectorsArray = [protSelector componentsSeparatedByString:@":"];

            if (selectorsArray.count > 1) {
                int argCount = 0;

                for (unsigned ad = 2; ad < [signature numberOfArguments]; ad++) {
                    argCount++;
                    NSString *sigCommonTypesString = [NSString stringWithCString:[signature cd_getArgumentTypeAtIndex:ad] encoding:NSUTF8StringEncoding];
                    NSString *space = ad == [signature numberOfArguments] - 1 ? @"" : @" ";
                    NSString *selectorObject = [selectorsArray objectAtIndex:ad - 2];
                    // NSLog(@"finstring: %@ selectorsArray: %@, selectorObject: %@, sigCommonTypesString: %@", finString, selectorsArray, selectorObject, sigCommonTypesString);
                    finString = [finString stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d%@", selectorObject, commonTypes(sigCommonTypesString, nil, NO), argCount, space]];
                }
            } else {
                finString = [finString stringByAppendingString:[NSString stringWithFormat:@"%@", [selectorsArray objectAtIndex:0]] ];
            }

            finString = [finString stringByAppendingString:@";"];
            [protocolsMethodsString appendString:[NSString stringWithFormat:@"%@(%@)%@\n", startSign, returnType, finString]];
            CDLog(@"protocolsMethodsString: %@", protocolsMethodsString);
        }

        free(protMeths);
    }

    //FIX EQUAL TYPES OF PROPERTIES AND METHODS
    NSArray *propertiesArray = propertiesArrayFromString(protPropertiesString);
    [protPropertiesString release];
    NSArray *lines = [protocolsMethodsString componentsSeparatedByString:@"\n"];
    NSMutableString *finalString = [[NSMutableString alloc] init];

    for (NSString *line in lines) {
        if (line.length > 0 && ([line rangeOfString:@"-"].location == 0 || [line rangeOfString:@"+"].location == 0)) {
            NSString *methodInLine = [line substringFromIndex:[line rangeOfString:@")"].location + 1];
            methodInLine = [methodInLine substringToIndex:[methodInLine rangeOfString:@";"].location];

            for (NSDictionary *dict in propertiesArray) {
                NSString *propertyName = [dict objectForKey:@"name"];

                if ([methodInLine rangeOfString:@"set"].location != NSNotFound) {
                    NSString *firstCapitalized = [[propertyName substringToIndex:1] capitalizedString];
                    NSString *capitalizedFirst = [firstCapitalized stringByAppendingString:[propertyName substringFromIndex:1]];

                    if ([methodInLine isEqual:[NSString stringWithFormat:@"set%@", capitalizedFirst] ]) {
                        // replace setter
                        if ([line rangeOfString:@":("].location != NSNotFound) {
                            NSString *newLine = [line substringToIndex:[line rangeOfString:@":("].location + 2];
                            newLine = [newLine stringByAppendingString:[dict objectForKey:@"type"]];
                            newLine = [newLine stringByAppendingString:[line substringFromIndex:[line rangeOfString:@")" options:4].location]];
                            line = newLine;
                        }
                    }
                }

                if ([methodInLine isEqual:propertyName]) {
                    NSString *newLine = [line substringToIndex:[line rangeOfString:@"("].location + 1];
                    newLine = [newLine stringByAppendingString:[NSString stringWithFormat:@"%@)%@;", [dict objectForKey:@"type"], [dict objectForKey:@"name"]]];
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
        [finalString release];
        finalString = [classesFoundToAdd mutableCopy];
        [classesFoundToAdd release];
    }

    [classesInProtocol release];
    [protocolsMethodsString release];
    [finalString appendString:@"@end\n\n"];
    return finalString;
}

static BOOL hasMalformedID(NSString *parts) {
    if ([parts rangeOfString:@"@\""].location != NSNotFound && [parts rangeOfString:@"@\""].location + 2 < parts.length - 1 &&  ([[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2] rangeOfString:@"\""].location == [[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2] rangeOfString:@"\"\""].location || [[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2] rangeOfString:@"\""].location == [[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2] rangeOfString:@"\"]"].location  || [[parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2] rangeOfString:@"\""].location == [parts substringFromIndex:[parts rangeOfString:@"@\""].location + 2].length - 1)) {
        return YES;
    }

    return NO;
}

/****** Structs Parser ******/


static NSString * representedStructFromStruct(NSString *inStruct, NSString *inName, BOOL inIvarList, BOOL isFinal) {
    if ([inStruct rangeOfString:@"\""].location == NSNotFound) { // not an ivar type struct, it has the names of types in quotes
        if ([inStruct rangeOfString:@"{?="].location == 0) {
            // UNKNOWN TYPE, WE WILL CONSTRUCT IT

            NSString *types = [inStruct substringFromIndex:3];
            types = [types substringToIndex:types.length - 1];

            for (NSDictionary *dict in allStructsFound) {
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
                    for (int i = 1; i < [result numberOfRanges]; i++) {
                        NSString *stringToPut = representedStructFromStruct([NSString stringWithFormat:@"{%@}", [types substringWithRange:[result rangeAtIndex:i]]], nil, NO, 0);
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

            for (NSDictionary *dict in allStructsFound) {
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

                        int replaceLocation = [types rangeOfString:str].location;
                        int replaceLength = str.length;
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
                    for (int i = 1; i < [result numberOfRanges]; i++) {
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
                    for (int i = 1; i < [result numberOfRanges]; i++) {
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

                int loc = [types rangeOfString:string].location;
                int length = string.length;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, length) withString:@"!"];
            }

            int fieldCount = 0;

            for (int i = 0; i < types.length; i++) {
                NSString *string = [types substringWithRange:NSMakeRange(i, 1)];

                if (![string isEqual:@"["] && ![string isEqual:@"]"] && ![string isEqual:@"{"] && ![string isEqual:@"}"] && ![string isEqual:@"\""] && ![string isEqual:@"b"] && ![string isEqual:@"("] && ![string isEqual:@")"]) {
                    fieldCount++;
                    NSString *newString = [NSString stringWithFormat:@"\"field%d\"%@", fieldCount, commonTypes(string, nil, NO)];
                    types = [types stringByReplacingCharactersInRange:NSMakeRange(i, 1) withString:[NSString stringWithFormat:@"\"field%d\"%@", fieldCount, commonTypes(string, nil, NO)]];
                    i += newString.length - 1;
                }
            }

            int fCounter = -1; // Separate counters used for debugging purposes

            while ([types rangeOfString:@"!"].location != NSNotFound) {
                fCounter++;
                int loc = [types rangeOfString:@"!"].location;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, 1) withString:[strctArray objectAtIndex:fCounter]];
            }
            int fCounter2 = -1;

            while ([types rangeOfString:@"~"].location != NSNotFound) {
                fCounter2++;
                int loc = [types rangeOfString:@"~"].location;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, 1) withString:[arrArray objectAtIndex:fCounter2]];
            }
            int fCounter3 = -1;

            while ([types rangeOfString:@"§"].location != NSNotFound) {
                fCounter3++;
                int loc = [types rangeOfString:@"§"].location;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, 1) withString:[bitArray objectAtIndex:fCounter3]];
            }
            int fCounter4 = -1;

            while ([types rangeOfString:@"+"].location != NSNotFound) {
                fCounter4++;
                int loc = [types rangeOfString:@"+"].location;
                types = [types stringByReplacingCharactersInRange:NSMakeRange(loc, 1) withString:[alreadyFoundStructs objectAtIndex:fCounter4]];
            }
            NSString *whatIBuilt = [NSString stringWithFormat:@"{?=%@}", types];

            if ([whatIBuilt isEqualToString:@"{?=}"]) {
                return whatIBuilt;
            }

            NSString *whatIReturn = representedStructFromStruct(whatIBuilt, nil, NO, YES);
            return whatIReturn;
        } else {
            if ([inStruct rangeOfString:@"="].location == NSNotFound) {
                inStruct = [inStruct stringByReplacingOccurrencesOfString:@"{" withString:@""];
                inStruct = [inStruct stringByReplacingOccurrencesOfString:@"}" withString:@""];
                return inStruct;
            }

            int firstIson = [inStruct rangeOfString:@"="].location;
            inStruct = [inStruct substringToIndex:firstIson];

            inStruct = [inStruct substringFromIndex:1];
            return inStruct;
        }
    }

    int firstBrace = [inStruct rangeOfString:@"{"].location;
    int ison = [inStruct rangeOfString:@"="].location;
    NSString *structName = [inStruct substringWithRange:NSMakeRange(firstBrace + 1, ison - 1)];

    NSString *parts = [inStruct substringFromIndex:ison + 1];
    parts = [parts substringToIndex:parts.length - 1]; // remove last character "}"

    if ([parts rangeOfString:@"{"].location == NSNotFound) { //does not contain other struct
        if (hasMalformedID(parts)) {
            while ([parts rangeOfString:@"@"].location != NSNotFound && hasMalformedID(parts)) {
                NSString *trialString = [parts substringFromIndex:[parts rangeOfString:@"@"].location + 2];

                if ([trialString rangeOfString:@"\""].location != [trialString rangeOfString:@"\"\""].location && [trialString rangeOfString:@"\""].location != trialString.length - 1 && [trialString rangeOfString:@"]"].location != [trialString rangeOfString:@"\""].location + 1) {
                    int location = [parts rangeOfString:@"@"].location;
                    parts = [parts stringByReplacingCharactersInRange:NSMakeRange(location - 1, 3) withString:@"\"id\""];
                }

                int location = [parts rangeOfString:@"@"].location;

                if ([parts rangeOfString:@"@"].location != NSNotFound) {
                    NSString *asubstring = [parts substringFromIndex:location + 2];

                    int nextlocation = [asubstring rangeOfString:@"\""].location;
                    asubstring = [asubstring substringWithRange:NSMakeRange(0, nextlocation)];

                    if ([classesInStructs indexOfObject:asubstring] == NSNotFound) {
                        [classesInStructs addObject:asubstring];
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
            structName = [NSString stringWithFormat:@"SCD_Struct_%@%d", classID, (int)[allStructsFound count]];
        }

        if ([structName rangeOfString:@"_"].location == 0) {
            structName = [structName substringFromIndex:1];
        }

        NSString *representation = reallyIsFlagInIvars ? @"struct {\n" : (wasKnown ? [NSString stringWithFormat:@"typedef struct %@ {\n", structName] : @"typedef struct {\n");

        for (int i = 0; i < [brokenParts count] - 1; i += 2) { // always an even number
            NSString *nam = [brokenParts objectAtIndex:i];
            NSString *typ = [brokenParts objectAtIndex:i + 1];
            types = [types stringByAppendingString:[brokenParts objectAtIndex:i + 1]];
            representation = reallyIsFlagInIvars ? [representation stringByAppendingString:[NSString stringWithFormat:@"\t\t%@ %@;\n", commonTypes(typ, &nam, NO), nam]] : [representation stringByAppendingString:[NSString stringWithFormat:@"\t%@ %@;\n", commonTypes(typ, &nam, NO), nam]];
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
            for (NSMutableDictionary *dict in allStructsFound) {
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

        for (NSDictionary *dict in allStructsFound) {
            if ([[dict objectForKey:@"name"] isEqual:structName]) {
                found = YES;
                return structName;

                break;
            }
        }

        if (!found) {
            for (NSMutableDictionary *dict in allStructsFound) {
                if ([[dict objectForKey:@"types"] isEqual:types] && !wasKnown) {
                    found = YES;
                    return [dict objectForKey:@"name"];
                }
            }
        }

        if (!found && !reallyIsFlagInIvars) {
            [allStructsFound addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:representation, @"representation", structName, @"name", types, @"types", nil]];
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
                for (int i = 1; i < [result numberOfRanges]; i++) {
                    blParts = [parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}", [parts substringWithRange:[result rangeAtIndex:i]]] withString:representedStructFromStruct([NSString stringWithFormat:@"{%@}", [parts substringWithRange:[result rangeAtIndex:i]]], nil, NO, 0)];
                    break;
                }
            }];
            parts = blParts;
        }
        NSString *rebuiltStruct = [NSString stringWithFormat:@"{%@=%@}", structName, parts];
        NSString *final = representedStructFromStruct(rebuiltStruct, nil, NO, YES);
        return final;
    }

    return inStruct;
}

/****** Unions Parser ******/


NSString * representedUnionFromUnion(NSString *inUnion) {
    if ([inUnion rangeOfString:@"\""].location == NSNotFound) {
        if ([inUnion rangeOfString:@"{?="].location == 0) {
            NSString *types = [inUnion substringFromIndex:3];
            types = [types substringToIndex:types.length - 1];

            for (NSDictionary *dict in allStructsFound) {
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

            int firstIson = [inUnion rangeOfString:@"="].location;
            inUnion = [inUnion substringToIndex:firstIson];
            inUnion = [inUnion substringFromIndex:1];
            return inUnion;
        }
    }

    int firstParenthesis = [inUnion rangeOfString:@"("].location;
    int ison = [inUnion rangeOfString:@"="].location;
    NSString *unionName = [inUnion substringWithRange:NSMakeRange(firstParenthesis + 1, ison - 1)];

    NSString *parts = [inUnion substringFromIndex:ison + 1];
    parts = [parts substringToIndex:parts.length - 1]; // remove last character "}"

    if ([parts rangeOfString:@"\"\"{"].location != NSNotFound) {
        parts = [parts stringByReplacingOccurrencesOfString:@"\"\"{" withString:@"\"field0\"{"];
    }

    if ([parts rangeOfString:@"("].location != NSNotFound) {
        while ([parts rangeOfString:@"("].location != NSNotFound) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\(([^\\(^\\)]+)\\)" options:NSRegularExpressionCaseInsensitive error:nil];
            __block NSString *unionParts;
            [regex enumerateMatchesInString:parts options:0
                                      range:NSMakeRange(0, [parts length])
                                 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
            {
                for (int i = 1; i < [result numberOfRanges]; i++) {
                    unionParts = [parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"(%@)", [parts substringWithRange:[result rangeAtIndex:i]]] withString:representedUnionFromUnion([NSString stringWithFormat:@"(%@)", [parts substringWithRange:[result rangeAtIndex:i]]])];
                    break;
                }
            }];
            parts = unionParts;
        }
    }

    if ([parts rangeOfString:@"{"].location != NSNotFound) {
        while ([parts rangeOfString:@"{"].location != NSNotFound) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\{([^\\{^\\}]+)\\}" options:NSRegularExpressionCaseInsensitive error:nil];
            __block NSString *structParts;
            [regex enumerateMatchesInString:parts options:0
                                      range:NSMakeRange(0, [parts length])
                                 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
            {
                for (int i = 1; i < [result numberOfRanges]; i++) {
                    structParts = [parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}", [parts substringWithRange:[result rangeAtIndex:i]]] withString:representedStructFromStruct([NSString stringWithFormat:@"{%@}", [parts substringWithRange:[result rangeAtIndex:i]]], nil, NO, NO)];
                    break;
                }
            }];
            parts = structParts;
        }
    }

    if (hasMalformedID(parts)) {
        while ([parts rangeOfString:@"@"].location != NSNotFound && hasMalformedID(parts)) {
            NSString *trialString = [parts substringFromIndex:[parts rangeOfString:@"@"].location + 2];

            if ([trialString rangeOfString:@"\""].location != [trialString rangeOfString:@"\"\""].location && [trialString rangeOfString:@"\""].location != trialString.length - 1 && [trialString rangeOfString:@"]"].location != [trialString rangeOfString:@"\""].location + 1) {
                int location = [parts rangeOfString:@"@"].location;
                parts = [parts stringByReplacingCharactersInRange:NSMakeRange(location - 1, 3) withString:@"\"id\""];
            }

            int location = [parts rangeOfString:@"@"].location;

            if ([parts rangeOfString:@"@"].location != NSNotFound) {
                NSString *asubstring = [parts substringFromIndex:location + 2];

                int nextlocation = [asubstring rangeOfString:@"\""].location;
                asubstring = [asubstring substringWithRange:NSMakeRange(0, nextlocation)];

                if ([classesInStructs indexOfObject:asubstring] == NSNotFound) {
                    [classesInStructs addObject:asubstring];
                }

                parts = [parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"@\"%@\"", asubstring] withString:[NSString stringWithFormat:@"^%@", asubstring]];
            }
        }
    }

    NSMutableArray *brokenParts = [[parts componentsSeparatedByString:@"\""] mutableCopy];
    [brokenParts removeObjectAtIndex:0];
    NSString *types = @"";

    BOOL wasKnown = 1;

    if ([unionName isEqual:@"?"]) {
        wasKnown = 0;
        unionName = [NSString stringWithFormat:@"SCD_Union_%@%d", classID, (int)[allStructsFound count]];
    }

    if ([unionName rangeOfString:@"_"].location == 0) {
        unionName = [unionName substringFromIndex:1];
    }

    NSString *representation = wasKnown ? [NSString stringWithFormat:@"typedef union %@ {\n", unionName] : @"typedef union {\n";
    int upCount = 0;

    for (int i = 0; i < [brokenParts count] - 1; i += 2) { // always an even number
        NSString *nam = [brokenParts objectAtIndex:i];
        upCount++;

        if ([nam rangeOfString:@"field0"].location != NSNotFound) {
            nam = [nam stringByReplacingOccurrencesOfString:@"field0" withString:[NSString stringWithFormat:@"field%d", upCount]];
        }

        NSString *typ = [brokenParts objectAtIndex:i + 1];
        types = [types stringByAppendingString:[brokenParts objectAtIndex:i + 1]];
        representation = [representation stringByAppendingString:[NSString stringWithFormat:@"\t%@ %@;\n", commonTypes(typ, &nam, NO), nam]];
    }

    representation = [representation stringByAppendingString:@"} "];
    representation = [representation stringByAppendingString:[NSString stringWithFormat:@"%@;\n\n", unionName]];
    BOOL found = NO;

    for (NSDictionary *dict in allStructsFound) {
        if ([[dict objectForKey:@"name"] isEqual:unionName]) {
            found = YES;
            return unionName;

            break;
        }
    }

    if (!found) {
        for (NSDictionary *dict in allStructsFound) {
            if ([[dict objectForKey:@"types"] isEqual:types] && !wasKnown) {
                found = YES;
                return [dict objectForKey:@"name"];

                break;
            }
        }
    }

    [allStructsFound addObject:[NSDictionary dictionaryWithObjectsAndKeys:representation, @"representation", unionName, @"name", types, @"types", nil]];

    return unionName != nil ? unionName : inUnion;
}

/****** Generic Types Parser ******/

NSString * commonTypes(NSString *atype, NSString **inName, BOOL inIvarList) {
    BOOL isRef = NO;
    BOOL isPointer = NO;
    BOOL isCArray = NO;
    BOOL isConst = NO;
    BOOL isOut = NO;
    BOOL isByCopy = NO;
    BOOL isByRef = NO;
    BOOL isOneWay = NO;


    /* Stripping off any extra identifiers to leave only the actual type for parsing later on */

    if ([atype rangeOfString:@"o"].location == 0 && ![commonTypes([atype substringFromIndex:1], nil, NO) isEqual:[atype substringFromIndex:1]]) {
        isOut = YES;
        atype = [atype substringFromIndex:1];
    }

    if ([atype rangeOfString:@"O"].location == 0 && ![commonTypes([atype substringFromIndex:1], nil, NO) isEqual:[atype substringFromIndex:1]]) {
        isByCopy = YES;
        atype = [atype substringFromIndex:1];
    }

    if ([atype rangeOfString:@"R"].location == 0 && ![commonTypes([atype substringFromIndex:1], nil, NO) isEqual:[atype substringFromIndex:1]]) {
        isByRef = YES;
        atype = [atype substringFromIndex:1];
    }

    if ([atype rangeOfString:@"V"].location == 0 && ![commonTypes([atype substringFromIndex:1], nil, NO) isEqual:[atype substringFromIndex:1]]) {
        isOneWay = YES;
        atype = [atype substringFromIndex:1];
    }

    if ([atype rangeOfString:@"r^{"].location == 0) {
        isConst = YES;
        atype = [atype substringFromIndex:2];
        isPointer = YES;
        shouldImportStructs = 1;
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
        atype = representedUnionFromUnion(atype);
    }

    int arrayCount = 0;

    if ([atype rangeOfString:@"["].location == 0) {
        isCArray = YES;

        if ([atype rangeOfString:@"{"].location != NSNotFound) {
            atype = [atype stringByReplacingOccurrencesOfString:@"[" withString:@""];
            atype = [atype stringByReplacingOccurrencesOfString:@"]" withString:@""];
            int firstBrace = [atype rangeOfString:@"{"].location;
            arrayCount = [[atype stringByReplacingCharactersInRange:NSMakeRange(firstBrace, atype.length - firstBrace) withString:@""] intValue];
            atype = [atype stringByReplacingCharactersInRange:NSMakeRange(0, firstBrace) withString:@""];
        } else {
            isCArray = NO;

            __block NSString *tempString = [atype mutableCopy];
            __block NSMutableArray *numberOfArray = [NSMutableArray array];

            while ([tempString rangeOfString:@"["].location != NSNotFound) {
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\[([^\\[^\\]]+)\\])" options:0 error:nil];

                [regex enumerateMatchesInString:tempString options:0
                                          range:NSMakeRange(0, [tempString length])
                                     usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
                {
                    for (int i = 1; i < [result numberOfRanges]; i++) {
                        NSString *foundString = [tempString substringWithRange:[result rangeAtIndex:i]];
                        tempString = [tempString stringByReplacingOccurrencesOfString:foundString withString:@""];
                        [numberOfArray addObject:foundString]; //e.g. [2] or [100c]
                        break;
                    }
                }];
            }




            NSString *stringContainingType;

            for (NSString *aString in numberOfArray) {
                NSCharacterSet *set = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLKMNOPQRSTUVWXYZ@#$%^&*()!<>?:\"|}{"] invertedSet];

                if ([aString rangeOfCharacterFromSet:set].location != NSNotFound) {
                    stringContainingType = aString;
                    break;
                }
            }

            [numberOfArray removeObject:stringContainingType];
            NSCharacterSet *set = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLKMNOPQRSTUVWXYZ@#$%^&*()!<>?:\"|}{"];
            int letterLocation = [stringContainingType rangeOfCharacterFromSet:set].location == NSNotFound ? -1 : [stringContainingType rangeOfCharacterFromSet:set].location;
            NSString *outtype = letterLocation == -1 ? stringContainingType : [stringContainingType substringFromIndex:letterLocation];
            outtype = [outtype stringByReplacingOccurrencesOfString:@"]" withString:@""];
            stringContainingType = [stringContainingType stringByReplacingOccurrencesOfString:outtype withString:@""];

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

    if ([atype rangeOfString:@"=}"].location != NSNotFound && [atype rangeOfString:@"{"].location == 0 && [atype rangeOfString:@"?"].location == NSNotFound  && [atype rangeOfString:@"\""].location == NSNotFound) {
        shouldImportStructs = 1;
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

        for (NSDictionary *dict in allStructsFound) {
            if ([[dict objectForKey:@"name"] isEqual:atype]) {
                found = YES;
                break;
            }
        }

        if (!found) {
            writeString = [writeString stringByAppendingString:[NSString stringWithFormat:@"%@Ref;\n\n", representedStructFromStruct(atype, nil, 0, NO)]];
            [allStructsFound addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObject:@""], @"types", writeString, @"representation", atype, @"name", nil]];
        }

        isRef = YES;
        isPointer = NO; // -> Ref
    }

    if ([atype rangeOfString:@"{"].location == 0) {
        if (inName != nil) {
            atype = representedStructFromStruct(atype, *inName, inIvarList, YES);
        } else {
            atype = representedStructFromStruct(atype, nil, inIvarList, YES);
        }

        if ([atype rangeOfString:@"_"].location == 0) {
            atype = [atype substringFromIndex:1];
        }

        shouldImportStructs = 1;
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

    if ([atype rangeOfString:@"N"].location == 0 && ![commonTypes([atype substringFromIndex:1], nil, NO) isEqual:[atype substringFromIndex:1]]) {
        atype = commonTypes([atype substringFromIndex:1], nil, NO);
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

    //if ([atype isEqual:  @"Q"]){ atype = @"uint64_t"; }

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

    if (isCArray && inName != nil) { //more checking to do, some framework were crashing if not nil, shouldn't be nil
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

/****** Methods Parser ******/
@implementation NSArray (Safe)

- (nullable id)objectAtSafeIndex:(NSUInteger)safeIndex {
    return safeIndex < self.count ? self[safeIndex] : nil;
}

@end
NSString * generateMethodLines(Class someclass, BOOL isInstanceMethod, NSMutableArray *propertiesArray) {
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
        //LOG_FILE_LINE;
        NSString *SelectorNameNS = [NSString stringWithCString:selectorName encoding:NSUTF8StringEncoding];

        if ([SelectorNameNS rangeOfString:@"."].location == 0) { //.cxx.destruct etc
            continue;
        }

        for (NSDictionary *dict in propertiesArray) {
            NSString *propertyName = [dict objectForKey:@"name"];

            if ([propertyName isEqual:SelectorNameNS]) {
                returnTypeSameAsProperty = [[dict objectForKey:@"type"] retain];
                break;
            }
        }

        NSString *startSign = isInstanceMethod ? @"-" : @"+";
        //LOG_FILE_LINE;
        NSString *startTypes = returnTypeSameAsProperty ? [NSString stringWithFormat:@"\n%@(%@)", startSign, returnTypeSameAsProperty] : [NSString stringWithFormat:@"\n%@(%@)", startSign, commonTypes([NSString stringWithCString:returnType encoding:NSUTF8StringEncoding], nil, NO)];
        [returnTypeSameAsProperty release];
        free(returnType);

        returnString = [[[returnString autorelease] stringByAppendingString:startTypes] retain];

        if (methodArgs > 2) {
            NSArray *selValuesArray = [SelectorNameNS componentsSeparatedByString:@":"];

            for (unsigned i = 2; i < methodArgs; i++) {
                char *methodType = method_copyArgumentType(currentMethod, i);
                NSString *methodTypeSameAsProperty = nil;

                if (methodArgs == 3) {
                    for (NSDictionary *dict in propertiesArray) {
                        NSString *propertyName = [dict objectForKey:@"name"];
                        NSString *firstCapitalized = [[propertyName substringToIndex:1] capitalizedString];
                        NSString *capitalizedFirst = [firstCapitalized stringByAppendingString:[propertyName substringFromIndex:1]];

                        if ([[selValuesArray objectAtIndex:0] isEqual:[NSString stringWithFormat:@"set%@", capitalizedFirst] ]) {
                            methodTypeSameAsProperty = [[dict objectForKey:@"type"] retain];
                            break;
                        }
                    }
                }

                if (methodTypeSameAsProperty) {
                    returnString = [[[returnString autorelease] stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d ", [selValuesArray objectAtIndex:i - 2], methodTypeSameAsProperty, i - 1]] retain];
                } else {
                    //LOG_FILE_LINE;
                    id object = [selValuesArray objectAtSafeIndex:i - 2];

                    if (object == nil) {
                        continue;
                    }

                    returnString = [[[returnString autorelease] stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d ", object, commonTypes([NSString stringWithCString:methodType encoding:NSUTF8StringEncoding], nil, NO), i - 1]] retain];
                }

                [methodTypeSameAsProperty release];
                free(methodType);
            }
        } else {
            returnString = [[[returnString autorelease] stringByAppendingString:[NSString stringWithFormat:@"%@", SelectorNameNS]] retain];
        }

        returnString = [[[returnString autorelease] stringByAppendingString:@";"] retain];
    }

    free(methodsArray);

    return returnString;
}

typedef void *MSImageRef;
//#include "substrate.h"

static const struct dyld_all_image_infos * (*my_dyld_get_all_image_infos)();
static MSImageRef (*_MSGetImageByName)(const char *name);
static void * (*_MSFindSymbol)(MSImageRef ref, const char *name);

static void findDyldGetAllImageInfosSymbol() {
    if (dlsym(RTLD_DEFAULT, "_dyld_get_all_image_infos")) {
        my_dyld_get_all_image_infos = (const struct dyld_all_image_infos *(*)(void))dlsym(RTLD_DEFAULT, "_dyld_get_all_image_infos");
    } else {
        // find libdyld.dylib ...
        unsigned int count;
        const char *dyldImage = NULL;
        const char **names = objc_copyImageNames(&count);

        for (unsigned int i = 0; i < count; i++) {
            if (strstr(names[i], "/libdyld.dylib")) {
                dyldImage = names[i];
                break;
            }
        }

        if (dyldImage) {
            _MSGetImageByName = (MSImageRef (*)(const char *))dlsym(RTLD_DEFAULT, "MSGetImageByName");
            _MSFindSymbol = (void *(*)(MSImageRef, const char *))dlsym(RTLD_DEFAULT, "MSFindSymbol");

            if (!_MSGetImageByName) { // are we in simulator ? try theos dir
                void *ms = dlopen("/opt/theos/lib/libsubstrate.dylib", RTLD_NOW);
                _MSGetImageByName = (MSImageRef (*)(const char *))dlsym(ms, "MSGetImageByName");
                _MSFindSymbol = (void *(*)(MSImageRef, const char *))dlsym(ms, "MSFindSymbol");
            }

            MSImageRef msImage = _MSGetImageByName(dyldImage);

            if (msImage) {
                void *msSymbol = _MSFindSymbol(msImage, "__dyld_get_all_image_infos");

                if (msSymbol) {
                    my_dyld_get_all_image_infos = (const struct dyld_all_image_infos *(*)(void))msSymbol;
                }
            }
        }
    }
}

static NSString * bash_escape(NSString *rawCommand) {
    NSString *escapedString = [rawCommand stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];

    escapedString = [escapedString stringByReplacingOccurrencesOfString:@" " withString:@"\\ "];
    return escapedString;
}

/****** Recursive file search ******/

static void list_dir(const char *dir_name, BOOL writeToDisk, NSString *outputDir, BOOL getSymbols, BOOL recursive, BOOL simpleHeader, BOOL skipAlreadyFound, BOOL skipApplications) {
    DIR *d;

    d = opendir(dir_name);

    if (!d) {
        return;
    }

    while (1) {
        struct dirent *entry;
        const char *d_name;

        entry = readdir(d);

        if (!entry) {
            break;
        }

        while (entry && entry->d_type == DT_LNK)
            entry = readdir(d);

        if (!entry) {
            break;
        }

        printf("  Scanning dir: %s...", dir_name);
        printf("\n\033[F\033[J");

        while (entry && (entry->d_type & DT_DIR) && (locationOfString(dir_name, [outputDir UTF8String]) == 0 ||  ((locationOfString(dir_name, "/private/var") == 0  || locationOfString(dir_name, "/var") == 0 || locationOfString(dir_name, "//var") == 0 || locationOfString(dir_name, "//private/var") == 0) && (skipApplications || (!skipApplications && !strstr(dir_name, "Application")))) || locationOfString(dir_name, "//dev") == 0 || locationOfString(dir_name, "//bin") == 0 ||  locationOfString(dir_name, "/dev") == 0 || locationOfString(dir_name, "/bin") == 0))
            entry = readdir(d);

        if (!entry) {
            break;
        }

        d_name = entry->d_name;

        if (strcmp(d_name, ".") && strcmp(d_name, "..")) {
            NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
            //LOG_FILE_LINE;
            NSString *currentPath = [NSString stringWithCString:dir_name encoding:NSUTF8StringEncoding];
            currentPath = [currentPath stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
            //LOG_FILE_LINE;
            NSString *currentFile = [NSString stringWithCString:d_name encoding:NSUTF8StringEncoding];
            NSString *imageToPass = [NSString stringWithFormat:@"%@/%@", currentPath, currentFile];
            CDLog(@"imageToPass: %@", imageToPass);

            if ([imageToPass rangeOfString:@"classdump-dyld"].location == NSNotFound && [imageToPass rangeOfString:@"/dev"].location != 0 && [imageToPass rangeOfString:@"/bin"].location != 0) {
                NSString *imageWithoutLastPart = [imageToPass stringByDeletingLastPathComponent];

                if ([[imageWithoutLastPart lastPathComponent] rangeOfString:@".app"].location != NSNotFound  || [[imageWithoutLastPart lastPathComponent] rangeOfString:@".framework"].location != NSNotFound || [[imageWithoutLastPart lastPathComponent] rangeOfString:@".bundle"].location != NSNotFound) {
                    NSString *skipString = [imageWithoutLastPart lastPathComponent];
                    //skipString=[skipString stringByDeletingPathExtension];
                    skipString = [skipString stringByReplacingOccurrencesOfString:@".framework" withString:@""];
                    skipString = [skipString stringByReplacingOccurrencesOfString:@".bundle" withString:@""];
                    skipString = [skipString stringByReplacingOccurrencesOfString:@".app" withString:@""];

                    if ([skipString isEqualToString:[imageToPass lastPathComponent]]) {
                        parseImage((char *)[imageToPass UTF8String ], writeToDisk, outputDir, getSymbols, recursive, YES, simpleHeader, skipAlreadyFound, skipApplications);
                    }
                } else {
                    parseImage((char *)[imageToPass UTF8String ], writeToDisk, outputDir, getSymbols, recursive, YES, simpleHeader, skipAlreadyFound, skipApplications);
                }
            }

            [p drain];
        }

        if (entry->d_type & DT_DIR) {
            if (strcmp(d_name, "..") != 0 && strcmp(d_name, ".") != 0) {
                int path_length;
                char path[PATH_MAX];

                path_length = snprintf(path, PATH_MAX, "%s/%s", dir_name, d_name);

                if (path_length >= PATH_MAX) {
                    //Path length has gotten too long
                    exit(EXIT_FAILURE);
                }

                list_dir(path, writeToDisk, outputDir, getSymbols, recursive, simpleHeader, skipAlreadyFound, skipApplications);
            }
        }
    }

    closedir(d);
}

/****** The actual job ******/

extern "C" int parseImage(char *image, BOOL writeToDisk, NSString *outputDir, BOOL getSymbols, BOOL isRecursive, BOOL buildOriginalDirs, BOOL simpleHeader, BOOL skipAlreadyFound, BOOL skipApplications) {
    if (!image) {
        return 3;
    }

    // applications are skipped by default in a recursive, you can use -a to force-dump them recursively
    if (skipApplications) {
        if (isRecursive && strstr(image, "/var/stash/Applications/")) { //skip Applications dir
            return 4;
        }

        if (isRecursive && strstr(image, "/var/mobile/Applications/")) { //skip Applications dir
            return 4;
        }

        if (isRecursive && strstr(image, "/var/mobile/Containers/Bundle/Application/")) { //skip Applications dir
            return 4;
        }

        if ((isRecursive && strstr(image, "SubstrateBootstrap.dylib") ) || (isRecursive && strstr(image, "CydiaSubstrate.framework"))) { //skip Applications dir
            return 4;
        }
    }

    if (isIOS11 && strstr(image, "SpringBoardUI")) {
        dlopen("/System/Library/PrivateFrameworks/SearchUI.framework/SearchUI", RTLD_NOW); //rdar://problem/26143166
    }

    NSString *imageAsNSString = [[NSString alloc] initWithCString:image encoding:NSUTF8StringEncoding];

    for (NSString *forbiddenPath in forbiddenPaths) {
        CDLog(@"imageAsNSString: %@", imageAsNSString);

        if ([imageAsNSString rangeOfString:forbiddenPath].location != NSNotFound) {
            NSLog(@"Image %@ cannot be parsed due to known crashing issues.", imageAsNSString);
            [imageAsNSString release];
            return 5;
        }
    }

    [imageAsNSString release];



    NSAutoreleasePool *xd = [[NSAutoreleasePool alloc] init];

    //LOG_FILE_LINE;
    if (isRecursive && ([[NSString stringWithCString:image encoding:NSUTF8StringEncoding] rangeOfString:@"/dev"].location == 0 || [[NSString stringWithCString:image encoding:NSUTF8StringEncoding] rangeOfString:@"/bin"].location == 0 || (skipApplications && [[NSString stringWithCString:image encoding:NSUTF8StringEncoding] rangeOfString:@"/var"].location == 0))) {
        [xd drain];
        return 4;
    }

    [xd drain];


    NSAutoreleasePool *xdd = [[NSAutoreleasePool alloc] init];

    //LOG_FILE_LINE;
    if ([allImagesProcessed containsObject:[NSString stringWithCString:image encoding:NSUTF8StringEncoding]]) {
        [xdd drain];
        return 5;
    }

    //LOG_FILE_LINE;
    NSString *imageEnd = [[NSString stringWithCString:image encoding:NSUTF8StringEncoding] lastPathComponent];
    imageEnd = [imageEnd stringByReplacingOccurrencesOfString:@".framework/" withString:@""];
    imageEnd = [imageEnd stringByReplacingOccurrencesOfString:@".framework" withString:@""];
    imageEnd = [imageEnd stringByReplacingOccurrencesOfString:@".bundle/" withString:@""];
    imageEnd = [imageEnd stringByReplacingOccurrencesOfString:@".bundle" withString:@""];
    imageEnd = [imageEnd stringByReplacingOccurrencesOfString:@".app/" withString:@""];
    imageEnd = [imageEnd stringByReplacingOccurrencesOfString:@".app" withString:@""];
    NSString *containedImage = [[NSString stringWithCString:image encoding:NSUTF8StringEncoding] stringByAppendingString:[NSString stringWithFormat:@"/%@", imageEnd]];

    if ([allImagesProcessed containsObject:containedImage]) {
        [xdd drain];
        return 5;
    }

    [xdd drain];


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

    if (opened) {
        CDLog(@"Will dlopen %s", image);
        @try {
            CDLog(@"try did not fail!");
            ref = dlopen(image,  RTLD_LAZY);
            CDLog(@"Did dlopen %s", image);
        } @catch (NSException *exception)   {
            NSLog(@"main.m: unable to load class from %s because of exception: %@", image, exception.reason);
        }
    } else {
        if (!isExec || shouldDLopen32BitExecutables) {
            if (!dlopenError || (dlopenError && !strstr(dlopenError, "no matching architecture in universal wrapper") && !strstr(dlopenError, "out of address space") && !strstr(dlopenError, "mach-o, but wrong architecture"))) {
                NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                NSString *imageString = [[NSString alloc] initWithCString:image encoding:NSUTF8StringEncoding];
                NSString *lastComponent = [imageString lastPathComponent];
                CDLog(@"lastComponent: %@", lastComponent);

                if ([lastComponent rangeOfString:@".framework"].location == NSNotFound && [lastComponent rangeOfString:@".bundle"].location == NSNotFound && [lastComponent rangeOfString:@".app"].location == NSNotFound) {
                    if (!isRecursive) {
                        dlopen_preflight(image);
                        printf("\nNot a suitable image: %s\n(%s)\n", image, dlerror());
                    }

                    return 3;
                }

                NSBundle *loadedBundle = [NSBundle bundleWithPath:imageString];
                [imageString release];
                [pool drain];
                char *exec = (char *)[[loadedBundle executablePath] UTF8String];
                image = (char *)exec;

                if (image) {
                    if (!dlopen_preflight(image)) {
                        // cleanup dlerror:
                        dlerror();
                        isExec = isMachOExecutable(image);
                    }

                    //opened=dlopen_preflight(image);
                    opened = dlopen_preflight([[loadedBundle executablePath] UTF8String]);
                    dlopenError = dlerror();
                } else {
                    opened = NO;
                }

                if (opened && (!isExec || shouldDLopen32BitExecutables)) {
                    ref = dlopen(image,  RTLD_LAZY);
                }
            }
        }
    }

    if (image != nil && ![allImagesProcessed containsObject:[NSString stringWithCString:image encoding:2]] && ((dlopenError && (strstr(dlopenError, "no matching architecture in universal wrapper") || strstr(dlopenError, "not macOS") || strstr(dlopenError, "out of address space") || strstr(dlopenError, "mach-o, but wrong architecture"))) || (isExec && !shouldDLopen32BitExecutables))) {
        @autoreleasepool{
            /*if (fileExistsOnDisk(image) && isExec){
               NSString *exec=[NSString stringWithFormat:@"/usr/bin/ldid -e %s > /tmp/entitlements/%@",image,[[NSString stringWithCString:image encoding:NSUTF8StringEncoding] lastPathComponent]];
               system([exec UTF8String]);
               }*/

            NSString *escapedImage = bash_escape([NSString stringWithUTF8String:image]);

#if defined (__x86_64__) || defined (__i386__)
            NSString *tryWithLib = [NSString stringWithFormat:@"DYLD_INSERT_LIBRARIES=/usr/local/lib/libclassdumpdyld.dylib %s", image];
            //#else
            //			NSString *tryWithLib=[NSString stringWithFormat:@"DYLD_INSERT_LIBRARIES=/usr/lib/libclassdumpdyld.dylib %s",image];
            //	NSString *tryWithLib=[NSString stringWithFormat:@"DYLD_INSERT_LIBRARIES=/usr/local/lib/libclassdumpdyld.dylib %@",escapedImage];
#else
            NSString *tryWithLib = [NSString stringWithFormat:@"DYLD_INSERT_LIBRARIES=/usr/lib/libclassdumpdyld.dylib %@", escapedImage];

#endif

            if (writeToDisk) {
                tryWithLib = [tryWithLib stringByAppendingString:[NSString stringWithFormat:@" -o %@", outputDir]];
            }

            if (buildOriginalDirs) {
                tryWithLib = [tryWithLib stringByAppendingString:@" -b"];
            }

            if (getSymbols) {
                tryWithLib = [tryWithLib stringByAppendingString:@" -g"];
            }

            if (simpleHeader) {
                tryWithLib = [tryWithLib stringByAppendingString:@" -u"];
            }

            if (addHeadersFolder) {
                tryWithLib = [tryWithLib stringByAppendingString:@" -h"];
            }

            if (inDebug) {
                tryWithLib = [tryWithLib stringByAppendingString:@" -D"];
            }

            if (isRecursive) {
                tryWithLib = [tryWithLib stringByAppendingString:@" -r"];
            }

            if (onlyOneClass) {
                tryWithLib = [tryWithLib stringByAppendingString:[NSString stringWithFormat:@" -j %@", onlyOneClass]];
            }

            //LOG_FILE_LINE;
            [allImagesProcessed addObject:[NSString stringWithCString:image encoding:2]];
            int (*_my_system)(const char *) = (int (*)(const char *))dlsym(RTLD_DEFAULT, "system");
            _my_system([tryWithLib UTF8String]);
        }

        if (!isRecursive) {
            return 1;
        }
    }

    if (!opened || ref == nil || image == NULL) {
        if (!isRecursive) {
            printf("\nCould not open: %s\n", image);
        }

        return 3;
    }

    //LOG_FILE_LINE;
    if (image != nil && [allImagesProcessed containsObject:[NSString stringWithCString:image encoding:2]]) {
        return 5;
    }

    CDLog(@"Dlopen complete, proceeding with class info for %s", image);
    // PROCEED
    BOOL isFramework = NO;
    NSMutableString *dumpString = [[NSMutableString alloc] initWithString:@""];
    unsigned int count;
    CDLog(@"Getting class count for %s", image);
    const char **names = objc_copyClassNamesForImage(image, &count);
    CDLog(@"Did return class count %d", count);

    if (count) {
        printf("  Dumping \"BOLDWHITE\"%s\"RESET\"...(%d classes) %s \n", image, count, [print_free_memory() UTF8String]);
    }

    while ([outputDir rangeOfString:@"/" options:NSBackwardsSearch].location == outputDir.length - 1)
        outputDir = [outputDir substringToIndex:outputDir.length - 1];

    BOOL hasWrittenCopyright = NO;
    allStructsFound = nil;
    allStructsFound = [NSMutableArray array];
    classesInStructs = nil;
    classesInStructs = [NSMutableArray array];


    NSMutableArray *protocolsAdded = [NSMutableArray array];
    //LOG_FILE_LINE;
    NSString *imageName = [[NSString stringWithCString:image encoding:NSUTF8StringEncoding] lastPathComponent];
    NSString *fullImageNameInNS = [NSString stringWithCString:image encoding:NSUTF8StringEncoding];
    [allImagesProcessed addObject:fullImageNameInNS];

    NSString *seeIfIsBundleType = [fullImageNameInNS stringByDeletingLastPathComponent];
    NSString *lastComponent = [seeIfIsBundleType lastPathComponent];
    NSString *targetDir = nil;
    CDLog(@"lastComponent: %@", lastComponent);

    if ([lastComponent rangeOfString:@"."].location == NSNotFound) {
        targetDir = fullImageNameInNS;
    } else {
        targetDir = [fullImageNameInNS stringByDeletingLastPathComponent];
        isFramework = YES;
    }

    NSString *headersFolder = addHeadersFolder ? @"/Headers" : @"";
    NSString *writeDir = buildOriginalDirs ? (isFramework ? [NSString stringWithFormat:@"%@/%@%@", outputDir, targetDir, headersFolder] : [NSString stringWithFormat:@"%@/%@", outputDir, targetDir]) : outputDir;
    writeDir = [writeDir stringByReplacingOccurrencesOfString:@"///" withString:@"/"];
    writeDir = [writeDir stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
    //LOG_FILE_LINE;
    [processedImages addObject:[NSString stringWithCString:image encoding:NSUTF8StringEncoding]];
    CDLog(@"Beginning class loop (%d classed) for %s", count, image);
    NSMutableString *classesToImport = [[NSMutableString alloc] init];

    int actuallyProcesssedCount = 0;

    for (unsigned i = 0; i < count; i++) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        classesInClass = nil;
        classesInClass = [NSMutableArray array];
        NSMutableArray *inlineProtocols = [NSMutableArray array];
        shouldImportStructs = 0;

        if (skipAlreadyFound && [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/%s.h", writeDir, names[i]]]) {
            continue;
        }

        BOOL canGetSuperclass = YES;
        NSString *classNameNSToRelease = [[NSString alloc] initWithCString:names[i] encoding:NSUTF8StringEncoding];

        if ([forbiddenClasses indexOfObject:classNameNSToRelease] != NSNotFound) {
            [classNameNSToRelease release];
            continue;
        }

        //NSLog(@"classNameNSToRelease: %@", classNameNSToRelease);
        if ([classNameNSToRelease rangeOfString:@"_INP"].location == 0 || [classNameNSToRelease rangeOfString:@"ASV"].location == 0) {
            [classNameNSToRelease release];
            continue;
        }

        if (onlyOneClass && ![classNameNSToRelease isEqual:onlyOneClass]) {
            [classNameNSToRelease release];
            continue;
        }

        [classNameNSToRelease release];

        actuallyProcesssedCount++;

        CDLog(@"Processing Class %s\n", names[i]);

        if (writeToDisk) {
            loadBar(i, count, 100, 50, names[i]);
        }

        //LOG_FILE_LINE;
        NSString *classNameNS = [NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding];
        CDLog(@"classNameNS: %@", classNameNS);

        if ([classNameNS isEqualToString:@"UINSServiceViewController"]) {
            continue;
        }

        while ([classNameNS rangeOfString:@"_"].location == 0)

            classNameNS = [classNameNS substringFromIndex:1];
        classID = [classNameNS substringToIndex:2];
        Class currentClass = nil;
        currentClass = objc_getClass(names[i]);

        if (!class_getClassMethod(currentClass, NSSelectorFromString(@"doesNotRecognizeSelector:") )) {
            canGetSuperclass = NO;
        }

        if (!class_getClassMethod(currentClass, NSSelectorFromString(@"methodSignatureForSelector:") )) {
            canGetSuperclass = NO;
        }

        if (strcmp((char *)image, (char *)"/System/Library/CoreServices/SpringBoard.app/SpringBoard") == 0) {
            [currentClass class]; //init a class instance to prevent crashes, specifically needed for some SpringBoard classes
        }

        @try {
            CDLog(@"Current class: %@", currentClass);
        } @catch (NSException *exception)   {
            NSLog(@"main.m: unable to create class from %@ because of exception: %@", classNameNS, exception.reason);
        }

        NSString *superclassString = canGetSuperclass ? ([[currentClass superclass] description] != nil ? [NSString stringWithFormat:@" : %@", [[currentClass superclass] description]] : @"") : @" : _UKNOWN_SUPERCLASS_";

        unsigned int protocolCount;
        Protocol **protocolArray = class_copyProtocolList(currentClass, &protocolCount);
        NSString *inlineProtocolsString = @"";

        //NSLog(@"protocol count: %i", protocolCount);
        for (unsigned t = 0; t < protocolCount; t++) {
            if (t == 0) {
                inlineProtocolsString = @" <";
            }

            const char *protocolName = protocol_getName(protocolArray[t]);
            //LOG_FILE_LINE;
            NSString *addedProtocol = [[NSString stringWithCString:protocolName encoding:NSUTF8StringEncoding] retain];

            if (t < protocolCount - 1) {
                addedProtocol = [[[addedProtocol autorelease] stringByAppendingString:@", "] retain];
            }

            inlineProtocolsString = [[[inlineProtocolsString autorelease] stringByAppendingString:addedProtocol] retain];

            if (t == protocolCount - 1) {
                inlineProtocolsString = [[[inlineProtocolsString autorelease] stringByAppendingString:@">"] retain];
            }
        }

        if (writeToDisk || (!writeToDisk && !hasWrittenCopyright)) {
            NSString *copyrightString = copyrightMessage(image);
            [dumpString appendString:copyrightString];
            [copyrightString release];
            hasWrittenCopyright = YES;
        }

        if (writeToDisk && superclassString.length > 0 && ![superclassString isEqual:@" : NSObject"]) {
            NSString *fixedSuperclass = [superclassString stringByReplacingOccurrencesOfString:@" : " withString:@""];
            NSString *importSuper = @"";

            if (!simpleHeader) {
                NSString *imagePrefix = [imageName substringToIndex:2];

                CDLog(@"imagePrefix: %@", classNameNS);
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
            //LOG_FILE_LINE;
            NSString *protocolNSString = [NSString stringWithCString:protocolName encoding:NSUTF8StringEncoding];

            if (writeToDisk) {
                if (simpleHeader) {
                    [dumpString appendString:[NSString stringWithFormat:@"#import \"%@.h\"\n", protocolNSString]];
                } else {
                    NSString *imagePrefix = [imageName substringToIndex:2];
                    NSString *protocolPrefix = nil;
                    NSString *imageOfProtocol = nil;

                    CDLog(@"protocolNSString: %@", protocolNSString);
                    protocolPrefix = [protocolNSString rangeOfString:@"_"].location == 0 ? [[protocolNSString substringFromIndex:1] substringToIndex:2] : [protocolNSString substringToIndex:2];
                    imageOfProtocol = ([imagePrefix isEqual:protocolPrefix] || !class_getImageName((Class)protocol) ) ? imageName : [NSString stringWithCString:class_getImageName((Class)protocol) encoding:NSUTF8StringEncoding];
                    imageOfProtocol = [imageOfProtocol lastPathComponent];

                    if ([protocolNSString rangeOfString:@"UI"].location == 0) {
                        imageOfProtocol = @"UIKit";
                    }

                    [dumpString appendString:[NSString stringWithFormat:@"#import <%@/%@.h>\n", imageOfProtocol, protocolNSString]];
                }
            }

            if ([protocolsAdded containsObject:protocolNSString]) {
                continue;
            }

            [protocolsAdded addObject:protocolNSString];
            NSString *protocolHeader = buildProtocolFile(protocol);

            if (strcmp(names[i], protocolName) == 0) {
                [dumpString appendString:protocolHeader];
            } else {
                if (writeToDisk) {
                    NSString *copyrightString = copyrightMessage(image);
                    protocolHeader = [copyrightString stringByAppendingString:protocolHeader];
                    [copyrightString release];

                    [[NSFileManager defaultManager] createDirectoryAtPath:writeDir withIntermediateDirectories:YES attributes:nil error:nil];

                    if (![protocolHeader writeToFile:[NSString stringWithFormat:@"%@/%s.h", writeDir, protocolName] atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
                        printf("  Failed to save protocol header to directory \"%s\"\n", [writeDir UTF8String]);
                    }
                } else {
                    [dumpString appendString:protocolHeader];
                }
            }
        }

        free(protocolArray);


        [dumpString appendString:[NSString stringWithFormat:@"\n@interface %s%@%@", names[i], superclassString, inlineProtocolsString]];
        // Get Ivars
        unsigned int ivarOutCount;
        Ivar *ivarArray = class_copyIvarList(currentClass, &ivarOutCount);

        if (ivarOutCount > 0) {
            [dumpString appendString:@" {\n"];

            for (unsigned x = 0; x < ivarOutCount; x++) {
                Ivar currentIvar = ivarArray[x];
                const char *ivarName = ivar_getName(currentIvar);
                CDLog(@"%i: %i of %i", __LINE__, x, ivarOutCount);
                NSString *ivarNameNS = [NSString stringWithCString:ivarName encoding:NSUTF8StringEncoding];
                const char *ivarType = ivar_getTypeEncoding(currentIvar);
                //LOG_FILE_LINE;
                NSString *ivarString = nil;
                @try {
                    ivarString = [NSString stringWithCString:ivarType encoding:NSUTF8StringEncoding];
                } @catch (NSException *exception)   {
                    DLog(@"main.m: unable to create string from '%@' because of exception: %@", ivarNameNS, exception.reason);
                }
                //NSLog(@"ivarString: %@ length: %lu", ivarString, ivarString.length);
                //sometimes the ivarString is funky and has an absurd length like 48,000+, that will lock us up until we run out of memory

                if (ivarString && ivarString.length < 10000) {
                    NSString *ivarTypeString = commonTypes(ivarString, &ivarNameNS, YES);

                    if ([ivarTypeString rangeOfString:@"@\""].location != NSNotFound) {
                        ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@"@\"" withString:@""];
                        ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@"\"" withString:@"*"];
                        NSString *classFoundInIvars = [ivarTypeString stringByReplacingOccurrencesOfString:@"*" withString:@""];

                        if (![classesInClass containsObject:classFoundInIvars]) {
                            CDLog(@"classFoundInIvars: %@", ivarTypeString);

                            if ([classFoundInIvars rangeOfString:@"<"].location != NSNotFound) {
                                int firstOpening = [classFoundInIvars rangeOfString:@"<"].location;

                                if (firstOpening != 0) {
                                    NSString *classToAdd = [classFoundInIvars substringToIndex:firstOpening];

                                    if (![classesInClass containsObject:classToAdd]) {
                                        [classesInClass addObject:classToAdd];
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
                                [classesInClass addObject:classFoundInIvars];
                            }
                        }

                        CDLog(@"%i: ivarTypeString: %@", __LINE__, ivarTypeString);

                        if ([ivarTypeString rangeOfString:@"<"].location != NSNotFound) {
                            ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@">*" withString:@">"];

                            if ([ivarTypeString rangeOfString:@"<"].location == 0) {
                                ivarTypeString = [@"id" stringByAppendingString:ivarTypeString];
                            } else {
                                ivarTypeString = [ivarTypeString stringByReplacingOccurrencesOfString:@"<" withString:@"*<"];
                            }
                        }
                    }

                    NSString *formatted = [NSString stringWithFormat:@"\n\t%@ %@;", ivarTypeString, ivarNameNS];
                    [dumpString appendString:formatted];
                }
            }

            [dumpString appendString:@"\n\n}"];
        }

        free(ivarArray);

        if ([inlineProtocols count] > 0) {
            NSMutableString *inlineProtocolsString = [[NSMutableString alloc] init];
            [inlineProtocolsString appendString:@"@protocol "];

            for (int g = 0; g < inlineProtocols.count; g++) {
                if (g < inlineProtocols.count - 1) {
                    [inlineProtocolsString appendString:[NSString stringWithFormat:@"%@, ", [inlineProtocols objectAtIndex:g]]];
                } else {
                    [inlineProtocolsString appendString:[NSString stringWithFormat:@"%@;\n", [inlineProtocols objectAtIndex:g]]];
                }
            }

            CDLog(@"dumpString: %@", dumpString);
            int interfaceLocation = [dumpString rangeOfString:@"@interface"].location;
            [dumpString insertString:inlineProtocolsString atIndex:interfaceLocation];
            [inlineProtocolsString release];
        }

        // Get Properties
        unsigned int propertiesCount;
        NSString *propertiesString = @"";
        objc_property_t *propertyList = class_copyPropertyList(currentClass, &propertiesCount);

        for (unsigned int b = 0; b < propertiesCount; b++) {
            const char *propname = property_getName(propertyList[b]);
            const char *attrs = property_getAttributes(propertyList[b]);
            //LOG_FILE_LINE;
            NSString *newString = propertyLineGenerator([NSString stringWithCString:attrs encoding:NSUTF8StringEncoding], [NSString stringWithCString:propname encoding:NSUTF8StringEncoding]);
            CDLog(@"propertiesString: %@", propertiesString);

            if ([propertiesString rangeOfString:newString].location == NSNotFound) {
                propertiesString = [[[propertiesString autorelease] stringByAppendingString:newString] retain];
            }

            [[newString autorelease] retain];
        }

        free(propertyList);



        // Fix synthesize locations
        int propLenght = [propertiesString length];
        NSMutableArray *synthesized = [[propertiesString componentsSeparatedByString:@"\n"] mutableCopy];
        int longestLocation = 0;

        for (NSString *string in synthesized) {
            string = [string stringByReplacingOccurrencesOfString:@"\t" withString:@""];
            string = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            CDLog(@"string: %@", string);
            int location = [string rangeOfString:@";"].location;

            if ([string rangeOfString:@";"].location == NSNotFound) {
                continue;
            }

            if (location > longestLocation) {
                longestLocation = location;
            }
        }

        NSMutableArray *newStrings = [NSMutableArray array];

        for (NSString *string in synthesized) {
            CDLog(@"string: %@", string);
            int synthesizeLocation = [string rangeOfString:@"//@synth"].location;

            if ([string rangeOfString:@"//@synth"].location == NSNotFound) {
                [newStrings addObject:string];
                continue;
            }

            NSString *copyString = [string substringFromIndex:synthesizeLocation];
            CDLog(@"string: %@", string);
            int location = [string rangeOfString:@";"].location;
            string = [string substringToIndex:location + 1];
            string = [string stringByPaddingToLength:longestLocation + 15 withString:@" " startingAtIndex:0];
            string = [string stringByAppendingString:copyString];
            [newStrings addObject:string];
        }

        if (propLenght > 0) {
            propertiesString = [@"\n" stringByAppendingString:[newStrings componentsJoinedByString:@"\n"]];
        }

        // Gather All Strings
        [dumpString appendString:propertiesString];
        [dumpString appendString:[generateMethodLines(object_getClass(currentClass), NO, nil) autorelease]];
        [dumpString appendString:[generateMethodLines(currentClass, YES, propertiesArrayFromString(propertiesString)) autorelease]];
        [dumpString appendString:@"\n@end\n\n"];

        if (shouldImportStructs && writeToDisk) {
            CDLog(@"dumpString: %@", dumpString);
            int firstImport = [dumpString rangeOfString:@"#import"].location != NSNotFound ? [dumpString rangeOfString:@"#import"].location : [dumpString rangeOfString:@"@interface"].location;
            NSString *structImport = simpleHeader ? [NSString stringWithFormat:@"#import \"%@-Structs.h\"\n", imageName] : [NSString stringWithFormat:@"#import <%@/%@-Structs.h>\n", imageName, imageName];
            [dumpString insertString:structImport atIndex:firstImport];
        }

        if (writeToDisk && [classesInClass count] > 0) {
            //LOG_FILE_LINE;
            [classesInClass removeObject:[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding]];

            if ([classesInClass count] > 0) {
                CDLog(@"dumpString: %@", dumpString);
                int firstInteface = [dumpString rangeOfString:@"@interface"].location;
                NSMutableString *classesFoundToAdd = [[NSMutableString alloc] init];
                [classesFoundToAdd appendString:@"@class "];

                for (int f = 0; f < classesInClass.count; f++) {
                    NSString *classFound = [classesInClass objectAtIndex:f];

                    if (f < classesInClass.count - 1) {
                        [classesFoundToAdd appendString:[NSString stringWithFormat:@"%@, ", classFound]];
                    } else {
                        [classesFoundToAdd appendString:[NSString stringWithFormat:@"%@;", classFound]];
                    }
                }

                [classesFoundToAdd appendString:@"\n\n"];
                [dumpString insertString:classesFoundToAdd atIndex:firstInteface];
                [classesFoundToAdd release];
            }
        }

        // Write strings to disk or print out
        NSError *writeError;

        if (writeToDisk) {
            //LOG_FILE_LINE;
            [[NSFileManager defaultManager] createDirectoryAtPath:writeDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *fileToWrite = [NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding];

            //LOG_FILE_LINE;
            if ([[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding] isEqual:[[NSString stringWithCString:image encoding:NSUTF8StringEncoding] lastPathComponent]]) {
                fileToWrite = [[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding] stringByAppendingString:@"-Class"];
            }

            if (![dumpString writeToFile:[NSString stringWithFormat:@"%@/%@.h", writeDir, fileToWrite] atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
                printf("  Failed to save to directory \"%s\"\n", [writeDir UTF8String]);
                exit(1);

                if (writeError != nil) {
                    printf("  %s\n", [[writeError description] UTF8String]);
                }

                break;
            }
        } else {
            printf("%s\n\n", [dumpString UTF8String]);
        }

        if (writeToDisk) {
            NSString *importStringFrmt = simpleHeader ? [NSString stringWithFormat:@"#import \"%s.h\"\n", names[i]] : [NSString stringWithFormat:@"#import <%@/%s.h>\n", imageName, names[i]];
            [classesToImport appendString:importStringFrmt];
        }

        objc_destructInstance(currentClass);

        [dumpString release];
        dumpString = [[NSMutableString alloc] init];
        [pool drain];
    }

    // END OF PER-CLASS LOOP

    if (actuallyProcesssedCount == 0 && onlyOneClass) {
        printf("\r\n\"BOLDWHITE\"\t\tlibclassdump-dyld:\"RESET\" Class \"\"BOLDWHITE\"%s\"RESET\"\" not found\"RESET\" in %s\r\n\r\n", [onlyOneClass UTF8String], image);
    }

    if (writeToDisk && classesToImport.length > 2) {
        [[NSFileManager defaultManager] createDirectoryAtPath:writeDir withIntermediateDirectories:YES attributes:nil error:nil];

        if (![classesToImport writeToFile:[NSString stringWithFormat:@"%@/%@.h", writeDir, imageName] atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            printf("  Failed to save header list to directory \"%s\"\n", [writeDir UTF8String]);
        }
    }

    [classesToImport release];


    CDLog(@"Finished class loop for %s", image);

    // Compose FrameworkName-Structs.h file

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if ([allStructsFound count] > 0) {
        NSString *structsString = @"";

        if (writeToDisk) {
            NSString *copyrightString = copyrightMessage(image);
            structsString = [[[structsString autorelease] stringByAppendingString:copyrightString] retain];
            [copyrightString release];
        }

        NSError *writeError;

        if ([classesInStructs count] > 0) {
            structsString = [[[structsString autorelease] stringByAppendingString:@"\n@class "] retain];

            for (NSString *string in classesInStructs) {
                structsString = [[[structsString autorelease] stringByAppendingString:[NSString stringWithFormat:@"%@, ", string]] retain];
            }

            structsString = [[[structsString autorelease] substringToIndex:structsString.length - 2] retain];
            structsString = [[[structsString autorelease] stringByAppendingString:@";\n\n"] retain];
        }

        for (NSDictionary *dict in allStructsFound) {
            structsString = [[[structsString autorelease] stringByAppendingString:[dict objectForKey:@"representation"]] retain];
        }

        if (writeToDisk) {
            [[NSFileManager defaultManager] createDirectoryAtPath:writeDir withIntermediateDirectories:YES attributes:nil error:nil];

            if (![structsString writeToFile:[NSString stringWithFormat:@"%@/%@-Structs.h", writeDir, imageName] atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
                printf("  Failed to save structs to directory \"%s\"\n", [writeDir UTF8String]);

                if (writeError != nil) {
                    printf("  %s\n", [[writeError description] UTF8String]);
                }
            }
        } else {
            printf("\n%s\n", [structsString UTF8String]);
        }
    }

    [pool drain];

    // Compose FrameworkName-Symbols.h file (more like nm command's output not an actual header anyway)
    if (getSymbols) {
        CDLog(@"In Symbols -> Fetching symbols for %s", image);

        struct mach_header *mh = nil;
        struct mach_header_64 *mh64 = nil;

        if (!my_dyld_get_all_image_infos) {
            findDyldGetAllImageInfosSymbol();
        }

        dyld_all_image_infos = my_dyld_get_all_image_infos();

        for (int i = 0; i < dyld_all_image_infos->infoArrayCount; i++) {
            if (dyld_all_image_infos->infoArray[i].imageLoadAddress != NULL) {
                char *currentImage = (char *)dyld_all_image_infos->infoArray[i].imageFilePath;

                if (strlen(currentImage) > 0 && !strcmp(currentImage, image)) {
                    if (arch64()) {
                        mh64 = (struct mach_header_64 *)dyld_all_image_infos->infoArray[i].imageLoadAddress;
                    } else {
                        mh = (struct mach_header *)dyld_all_image_infos->infoArray[i].imageLoadAddress;
                    }

                    break;
                }
            }
        }

        if ((arch64() && mh64 == nil) | (!arch64() && mh == nil)) {
            CDLog(@"Currently dlopened image %s not found in _dyld_image_count (?)", image);
        } else {
            unsigned int file_slide;
            NSMutableString *symbolsString = nil;

            if (!arch64()) {
                CDLog(@"In Symbols -> Got mach header OK , filetype %d", mh->filetype);

                // Thanks to FilippoBiga for the code snippet below

                struct segment_command *seg_linkedit = NULL;
                struct segment_command *seg_text = NULL;
                struct symtab_command *symtab = NULL;
                struct load_command *cmd =  (struct load_command *)((char *)mh + sizeof(struct mach_header));
                CDLog(@"In Symbols -> Iterating header commands for %s", image);

                for (uint32_t index = 0; index < mh->ncmds; index++, cmd = (struct load_command *)((char *)cmd + cmd->cmdsize)) {
                    //CDLog(@"I=%d",index);
                    switch (cmd->cmd) {
                        case LC_SEGMENT:{
                            //CDLog(@"FOUND LC_SEGMENT");
                            struct segment_command *segmentCommand = (struct segment_command *)(cmd);

                            if (strncmp(segmentCommand->segname, "__TEXT", sizeof(segmentCommand->segname)) == 0) {
                                seg_text = segmentCommand;
                            } else if (strncmp(segmentCommand->segname, "__LINKEDIT", sizeof(segmentCommand->segname)) == 0) {
                                seg_linkedit = segmentCommand;
                            }

                            break;
                        }

                        case LC_SYMTAB:{
                            //CDLog(@"FOUND SYMTAB");
                            symtab = (struct symtab_command *)(cmd);
                            break;
                        }

                        default:{
                            break;
                        }
                    }
                }

                if (mh->filetype == MH_DYLIB) {
                    file_slide = ((unsigned long)seg_linkedit->vmaddr - (unsigned long)seg_text->vmaddr) - seg_linkedit->fileoff;
                } else {
                    file_slide = 0;
                }

                CDLog(@"In Symbols -> Got symtab for %s", image);
                struct nlist *symbase = (struct nlist *)((unsigned long)mh + (symtab->symoff + file_slide));
                char *strings = (char *)((unsigned long)mh + (symtab->stroff + file_slide));
                struct nlist *sym;
                sym = symbase;

                symbolsString = [[NSMutableString alloc] init];
                NSAutoreleasePool *pp = [[NSAutoreleasePool alloc] init];

                CDLog(@"In Symbols -> Iteraring symtab");

                for (uint32_t index = 0; index < symtab->nsyms; index += 1, sym += 1) {
                    if ((uint32_t)sym->n_un.n_strx > symtab->strsize) {
                        break;
                    } else {
                        const char *strFound = (char *)(strings + sym->n_un.n_strx);
                        char *str = strdup(strFound);

                        if (strcmp(str, "<redacted>") && strlen(str) > 0) {
                            if (!symbolsString) {
                                NSString *copyrightString = copyrightMessage(image);
                                [symbolsString appendString:[copyrightString stringByReplacingOccurrencesOfString:@"This header" withString:@"This output"]];
                                [copyrightString release];
                                [symbolsString appendString:[NSString stringWithFormat:@"\nSymbols found in %s:\n%@\n", image, [NSString stringWithCString:str encoding:NSUTF8StringEncoding]]];
                            } else {
                                [symbolsString appendString:[NSString stringWithFormat:@"%s\n", str]];
                            }
                        }

                        free(str);
                    }
                }

                [pp drain];
            } else {
                CDLog(@"In Symbols -> Got mach header OK , filetype %d", mh64->filetype);

                struct segment_command_64 *seg_linkedit = NULL;
                struct segment_command_64 *seg_text = NULL;
                struct symtab_command *symtab = NULL;
                struct load_command *cmd = (struct load_command *)((char *)mh64 + sizeof(struct mach_header_64));
                CDLog(@"In Symbols -> Iterating header commands for %s", image);

                for (uint32_t index = 0; index < mh64->ncmds; index++, cmd = (struct load_command *)((char *)cmd + cmd->cmdsize)) {
                    //CDLog(@"I=%d",index);
                    switch (cmd->cmd) {
                        case LC_SEGMENT_64:{
                            //CDLog(@"FOUND LC_SEGMENT_64");
                            struct segment_command_64 *segmentCommand = (struct segment_command_64 *)(cmd);

                            if (strncmp(segmentCommand->segname, "__TEXT", sizeof(segmentCommand->segname)) == 0) {
                                seg_text = segmentCommand;
                            } else if (strncmp(segmentCommand->segname, "__LINKEDIT", sizeof(segmentCommand->segname)) == 0) {
                                seg_linkedit = segmentCommand;
                            }

                            break;
                        }

                        case LC_SYMTAB:{
                            //CDLog(@"FOUND SYMTAB");
                            symtab = (struct symtab_command *)(cmd);
                            break;
                        }

                        default:{
                            break;
                        }
                    }
                }

                if (mh64->filetype == MH_DYLIB) {
                    file_slide = ((unsigned long)seg_linkedit->vmaddr - (unsigned long)seg_text->vmaddr) - seg_linkedit->fileoff;
                } else {
                    file_slide = 0;
                }

                CDLog(@"In Symbols -> Got symtab for %s", image);
                struct nlist_64 *symbase = (struct nlist_64 *)((unsigned long)mh64 + (symtab->symoff + file_slide));
                char *strings = (char *)((unsigned long)mh64 + (symtab->stroff + file_slide));
                struct nlist_64 *sym;
                sym = symbase;

                symbolsString = [[NSMutableString alloc] init];
                NSAutoreleasePool *pp = [[NSAutoreleasePool alloc] init];

                CDLog(@"In Symbols -> Iteraring symtab");

                for (uint32_t index = 0; index < symtab->nsyms; index += 1, sym += 1) {
                    if ((uint32_t)sym->n_un.n_strx > symtab->strsize) {
                        break;
                    } else {
                        const char *strFound = (char *)(strings + sym->n_un.n_strx);
                        char *str = strdup(strFound);

                        if (strcmp(str, "<redacted>") && strlen(str) > 0) {
                            if (!symbolsString) {
                                NSString *copyrightString = copyrightMessage(image);
                                [symbolsString appendString:[copyrightString stringByReplacingOccurrencesOfString:@"This header" withString:@"This output"]];
                                [copyrightString release];
                                [symbolsString appendString:[NSString stringWithFormat:@"\nSymbols found in %s:\n%@\n", image, [NSString stringWithCString:str encoding:NSUTF8StringEncoding]]];
                            } else {
                                [symbolsString appendString:[NSString stringWithFormat:@"%s\n", str]];
                            }
                        }

                        free(str);
                    }
                }

                [pp drain];
            }

            NSError *error2;
            CDLog(@"Finished fetching symbols for %s\n", image);

            if ([symbolsString length] > 0) {
                if (writeToDisk) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:writeDir withIntermediateDirectories:YES attributes:nil error:&error2];

                    if (![symbolsString writeToFile:[NSString stringWithFormat:@"%@/%@-Symbols.h", writeDir, imageName] atomically:YES encoding:NSUTF8StringEncoding error:&error2]) {
                        printf("  Failed to save symbols to directory \"%s\"\n", [writeDir UTF8String]);

                        if (error2 != nil) {
                            printf("  %s\n", [[error2 description] UTF8String]);
                        }
                    }
                } else {
                    printf("\n%s\n", [symbolsString UTF8String]);
                }
            }

            [symbolsString release];
        }
    }

    free(names);

    return 1;
}

/****** main ******/

int main(int argc, char **argv, char **envp) {
    isIOS11 = [[[NSProcessInfo processInfo] operatingSystemVersionString] rangeOfString:@"Version 11"].location == 0 || [[[NSProcessInfo processInfo] operatingSystemVersionString] rangeOfString:@"Version 12"].location == 0;

    @autoreleasepool {
        char *image = nil;
        BOOL writeToDisk = NO;
        BOOL buildOriginalDirs = NO;
        BOOL recursive = NO;
        BOOL simpleHeader = NO;
        BOOL getSymbols = NO;
        BOOL skipAlreadyFound = NO;
        BOOL isSharedCacheRecursive = NO;
        BOOL skipApplications = YES;



        NSString *outputDir = nil;
        NSString *sourceDir = nil;
        NSString *userBlFile = nil;

        // Check and apply arguments

        NSString *currentDir = [[[NSProcessInfo processInfo] environment] objectForKey:@"PWD"];
        NSMutableArray *arguments = [[NSProcessInfo processInfo] arguments].mutableCopy;
        [arguments addObject:@"-o"];
        [arguments addObject:@"/Users/jh/Desktop/dump"];
        [arguments addObject:@"-c"];
        NSMutableArray *argumentsToUse = [arguments mutableCopy];
        [argumentsToUse removeObjectAtIndex:0];

        int argCount = [arguments count];

        if (argCount < 2) {
            printHelp();
            exit(0);
        }

        for (NSString *arg in arguments) {
            if ([arg isEqual:@"-D"]) {
                inDebug = 1;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-B"]) {
                CDLog(@"new blacklist science!");
                int argIndex = [arguments indexOfObject:arg];

                if (argIndex == argCount - 1) {
                    printHelp();
                    exit(0);
                }

                userBlFile = [arguments objectAtIndex:argIndex + 1];
                NSString *file = [currentDir stringByAppendingPathComponent:userBlFile];
                NSString *rawFile = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];//[[NSString alloc] initWithContentsOfFile:file error:nil];
                userBlacklisted = [rawFile componentsSeparatedByString:@"\n"];
                CDLog(@"userBlacklisted: %@", userBlacklisted);
                [argumentsToUse removeObject:arg];
                [argumentsToUse removeObject:userBlFile];
            }

            if ([arg isEqual:@"-o"]) {
                int argIndex = [arguments indexOfObject:arg];

                if (argIndex == argCount - 1) {
                    printHelp();
                    exit(0);
                }

                outputDir = [arguments objectAtIndex:argIndex + 1];

                //outputDir=[NSString stringWithFormat:@"\"%@\"",outputDir];
                if ([outputDir rangeOfString:@"-"].location == 0) {
                    printHelp();
                    exit(0);
                }

                writeToDisk = YES;
                [argumentsToUse removeObject:arg];
                [argumentsToUse removeObject:outputDir];
            }

            if ([arg isEqual:@"-j"]) {
                int argIndex = [arguments indexOfObject:arg];

                if (argIndex == argCount - 1) {
                    printHelp();
                    exit(0);
                }

                onlyOneClass = [[arguments objectAtIndex:argIndex + 1] retain];

                CDLog(@"onlyOneClass: %@", onlyOneClass);

                if ([onlyOneClass rangeOfString:@"-"].location == 0) {
                    printHelp();
                    exit(0);
                }

                [argumentsToUse removeObject:arg];
                [argumentsToUse removeObject:onlyOneClass];
            }

            if ([arg isEqual:@"-r"]) {
                int argIndex = [arguments indexOfObject:arg];

                if (argIndex == argCount - 1) {
                    printHelp();
                    exit(0);
                }

                sourceDir = [arguments objectAtIndex:argIndex + 1];
                BOOL isDir;
                CDLog(@"sourceDir: %@", onlyOneClass);

                if ([sourceDir rangeOfString:@"-"].location == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:sourceDir] || ([[NSFileManager defaultManager] fileExistsAtPath:sourceDir isDirectory:&isDir] && !isDir)) {
                    printf("classdump-dyld: error: Directory %s does not exist\n", [sourceDir UTF8String]);
                    exit(0);
                }

                recursive = YES;
                [argumentsToUse removeObject:arg];
                [argumentsToUse removeObject:sourceDir];
            }

            if ([arg isEqual:@"-a"]) {
                skipApplications = NO;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-e"]) {
                shouldDLopen32BitExecutables = YES;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-s"]) {
                skipAlreadyFound = YES;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-b"]) {
                buildOriginalDirs = YES;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-g"]) {
                getSymbols = YES;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-u"]) {
                simpleHeader = YES;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-c"]) {
                isSharedCacheRecursive = YES;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-h"]) {
                addHeadersFolder = YES;
                [argumentsToUse removeObject:arg];
            }

            if ([arg isEqual:@"-x"]) {
                int argIndex = [arguments indexOfObject:arg];

                if (argIndex == argCount - 1) {
                    printHelp();
                    exit(0);
                }

                int nextEntriesCount = [arguments count] - argIndex - 1;
                int next = 1;

                while (nextEntriesCount) {
                    NSString *forbiddenClassAdd = [arguments objectAtIndex:argIndex + next];
                    next++;
                    nextEntriesCount--;

                    if ([forbiddenClassAdd rangeOfString:@"-"].location == 0) {
                        nextEntriesCount = 0;
                        break;
                    }

                    if (!forbiddenClasses) {
                        generateForbiddenClassesArray(recursive);
                    }

                    [forbiddenClasses addObject:forbiddenClassAdd];
                    [argumentsToUse removeObject:forbiddenClassAdd];
                }

                [argumentsToUse removeObject:arg];
            }
        }

        if (onlyOneClass && (recursive || isSharedCacheRecursive)) {
            printHelp();
            exit(0);
        }

        if (addHeadersFolder && !outputDir) {
            printHelp();
            exit(0);
        }

        if ((recursive || isSharedCacheRecursive) && !outputDir) {
            printHelp();
            exit(0);
        }

        if ((recursive || isSharedCacheRecursive) && [argumentsToUse count] > 0) {
            printHelp();
            exit(0);
        }

        if ([argumentsToUse count] > 2) {
            printHelp();
            exit(0);
        }

        if (!recursive && !isSharedCacheRecursive) {
            if ([argumentsToUse count] > 1) {
                printHelp();
                exit(0);
            } else {
                if ([argumentsToUse count] > 0) {
                    image = (char *)[[argumentsToUse objectAtIndex:0] UTF8String];
                } else {
                    printHelp();
                    exit(0);
                }
            }
        }

        if (recursive && isSharedCacheRecursive) {
            skipAlreadyFound = YES;
        }

        // Begin

        int RESULT = 1;

        allImagesProcessed = [NSMutableArray array];

        if (!forbiddenClasses) {
            generateForbiddenClassesArray(recursive);
        }

        generateForbiddenPathsArray(recursive);

        NSString *inoutputDir = outputDir;

        if (isSharedCacheRecursive) {
            const char *filename = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e";
            FILE *fp = fopen(filename, "r");

            if (fp == NULL) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:@"/private/var/db/dyld/dyld_shared_cache_x86_64"]) {
                    filename = "/private/var/db/dyld/dyld_shared_cache_x86_64";
                } else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/private/var/db/dyld/dyld_shared_cache_i386"]) {
                    filename = "/private/var/db/dyld/dyld_shared_cache_i386";
                } else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64"]) {
                    filename = "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64";
                } else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s"]) {
                    filename = "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s";
                } else {
                    filename = "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7";
                }
            }

            fclose(fp);
            printf("\n   Now dumping \"BOLDWHITE\"%s...\"RESET\"\n\n", filename);
            // Thanks to DHowett & KennyTM~ for dyld_shared_cache listing codes
            struct stat filebuffer;
            stat(filename, &filebuffer);
            unsigned long long filesize = filebuffer.st_size;
            //2031403008
            unsigned long long leftovers = 0;
            unsigned long long originalSize = filesize;

            if (filesize > SIZE_LIMIT) {
                leftovers = filesize - SIZE_LIMIT;
                filesize = SIZE_LIMIT;
            }

            //NSLog(@"file size: %llu", filesize);
            int fd = open(filename, O_RDONLY);
            _cacheData = (uint8_t *)mmap(NULL, filesize, PROT_READ, MAP_PRIVATE, fd, 0);
            _cacheHead = (struct cache_header *)_cacheData;
            uint64_t curoffset = _cacheHead->imagesOffset;
            int currentIndex = 0;
            uint64_t currentFo = 0;

            //NSLog(@"lib count: %i", _cacheHead->numlibs);
            for (unsigned i = 0; i < _cacheHead->imagesCount; ++i) {
                //LOG_FILE_LINE;
                uint64_t fo = *(uint64_t *)(_cacheData + curoffset + 24);
                CDLog(@"fo: %llu offset: %llu index: %i / %i", fo, curoffset, i, _cacheHead->imagesCount);
                curoffset += 32;

                if (fo > filesize) {
                    NSLog(@"stopping at lib index: %i", i);
                    continue;
                }

                currentIndex = i + 1;//(because this is ++i for loop)
                currentFo = fo;
                char *imageInCache = (char *)_cacheData + fo;

                // a few blacklisted frameworks that crash
                if (strstr(imageInCache, "iWorkImport.framework") ||
                    strstr(imageInCache, "TSReading") ||
                    strstr(imageInCache, "TSStyles") ||
                    strstr(imageInCache, "PencilPairingUI") ||
                    strstr(imageInCache, "Powerlog") ||
                    strstr(imageInCache, "Parsec") ||
                    strstr(imageInCache, "WebKitLegacy") ||
                    strstr(imageInCache, "VisualVoicemail") ||
                    strstr(imageInCache, "/System/Library/Frameworks/CoreGraphics.framework/Resources/") ||
                    strstr(imageInCache, "JavaScriptCore.framework") ||
                    strstr(imageInCache, "GameKitServices.framework") ||
                    strstr(imageInCache, "SpringBoardUI.framework") ||
                    strstr(imageInCache, "CameraEffectsKit.framework") ||
                    strstr(imageInCache, "VectorKit")) {
                    continue;
                }

                NSMutableString *imageToNSString = [[NSMutableString alloc] initWithCString:imageInCache encoding:NSUTF8StringEncoding];
                [imageToNSString replaceOccurrencesOfString:@"///" withString:@"/" options:0 range:NSMakeRange(0, [imageToNSString length])];
                [imageToNSString replaceOccurrencesOfString:@"//" withString:@"/" options:0 range:NSMakeRange(0, [imageToNSString length])];
                CDLog(@"Current Image %@", imageToNSString);
                BOOL userDidBlacklist = false;

                for (NSString *blItem in userBlacklisted) {
                    if ([imageToNSString containsString:blItem]) {
                        //NSLog(@"access denied! user blacklisted: %@", imageToNSString);
                        printf(BOLDWHITE"ACCESS DENIED!\"RESET\" User blacklisted: %s\n", imageInCache);
                        userDidBlacklist = true;
                    }
                }

                if (!userDidBlacklist) {
                    parseImage((char *)[imageToNSString UTF8String], writeToDisk, outputDir, getSymbols, YES, YES, simpleHeader, skipAlreadyFound, skipApplications);
                }

                [imageToNSString release];
            }

            int itemsLeft = _cacheHead->imagesCount - currentIndex;
            munmap(_cacheData, filesize);
            leftovers = originalSize - currentFo;

            //NSLog(@"items left: %i currentFo: %lu leftovers: %lu", itemsLeft, currentFo, leftovers);
            if (leftovers > 0) {
                //NSLog(@"starting leftovers!!");
                _cacheData = (uint8_t *)mmap(NULL, leftovers, PROT_READ, MAP_PRIVATE, fd, currentFo);

                //LOG_FILE_LINE;
                for (unsigned i = currentIndex; i < currentIndex + itemsLeft; ++i) {
                    //LOG_FILE_LINE;
                    uint64_t fo = *(uint64_t *)(_cacheData + curoffset + 24);
                    curoffset += 32;
                    char *imageInCache = (char *)_cacheData + fo;

                    //LOG_FILE_LINE;
                    // a few blacklisted frameworks that crash
                    if (strstr(imageInCache, "iWorkImport.framework") ||
                        strstr(imageInCache, "TSReading") ||
                        strstr(imageInCache, "TSStyles") ||
                        strstr(imageInCache, "PencilPairingUI") ||
                        strstr(imageInCache, "Powerlog") ||
                        strstr(imageInCache, "Parsec") ||
                        strstr(imageInCache, "WebKitLegacy") ||
                        strstr(imageInCache, "VisualVoicemail") ||
                        strstr(imageInCache, "/System/Library/Frameworks/CoreGraphics.framework/Resources/") ||
                        strstr(imageInCache, "JavaScriptCore.framework") ||
                        strstr(imageInCache, "GameKitServices.framework") ||
                        strstr(imageInCache, "VectorKit")) {
                        continue;
                    }

                    //LOG_FILE_LINE;
                    NSMutableString *imageToNSString = [[NSMutableString alloc] initWithCString:imageInCache encoding:NSUTF8StringEncoding];
                    [imageToNSString replaceOccurrencesOfString:@"///" withString:@"/" options:0 range:NSMakeRange(0, [imageToNSString length])];
                    [imageToNSString replaceOccurrencesOfString:@"//" withString:@"/" options:0 range:NSMakeRange(0, [imageToNSString length])];
                    CDLog(@"Current Image %@", imageToNSString);
                    parseImage((char *)[imageToNSString UTF8String], writeToDisk, outputDir, getSymbols, YES, YES, simpleHeader, skipAlreadyFound, skipApplications);
                    [imageToNSString release];
                }

                //LOG_FILE_LINE;
                munmap(_cacheData, filesize);
            }

            close(fd);

            printf("\n   Finished dumping \"BOLDWHITE\"%s...\"RESET\"\n\n", filename);
        }

        if (recursive) {
            NSFileManager *fileman = [[NSFileManager alloc ] init];
            NSError *error;
            [fileman createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:&error];

            if (error) {
                NSLog(@"Could not create directory %@. Check permissions.", outputDir);
                exit(EXIT_FAILURE);
            }

            [fileman changeCurrentDirectoryPath:currentDir];
            [fileman changeCurrentDirectoryPath:outputDir];
            outputDir = [fileman currentDirectoryPath];
            [fileman changeCurrentDirectoryPath:currentDir];
            [fileman changeCurrentDirectoryPath:sourceDir];
            sourceDir = [fileman currentDirectoryPath];
            [fileman release];
            const char *dir_name = [sourceDir UTF8String];
            list_dir(dir_name, writeToDisk, outputDir, getSymbols, recursive, simpleHeader, skipAlreadyFound, skipApplications);
        } else {
            if (image) {
                NSError *error;
                NSFileManager *fileman = [[NSFileManager alloc ] init];
                NSString *imageString = nil;

                if (outputDir) {
                    [fileman createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:&error];

                    if (error) {
                        NSLog(@"Could not create directory %@. Check permissions.", outputDir);
                        exit(EXIT_FAILURE);
                    }

                    [fileman changeCurrentDirectoryPath:currentDir];
                    [fileman changeCurrentDirectoryPath:outputDir];
                    outputDir = [fileman currentDirectoryPath];
                    //LOG_FILE_LINE;
                    imageString = [NSString stringWithCString:image encoding:NSUTF8StringEncoding];
                    CDLog(@"imageString: %@", imageString);

                    if ([imageString rangeOfString:@"/"].location != 0) { // not an absolute path
                        [fileman changeCurrentDirectoryPath:currentDir];
                        NSString *append = [imageString lastPathComponent];
                        NSString *source = [imageString stringByDeletingLastPathComponent];
                        [fileman changeCurrentDirectoryPath:source];
                        imageString = [[fileman currentDirectoryPath] stringByAppendingString:[NSString stringWithFormat:@"/%@", append]];
                        image = (char *)[imageString UTF8String];
                    }
                }

                RESULT = parseImage(image, writeToDisk, outputDir, getSymbols, NO, buildOriginalDirs, simpleHeader, NO, skipApplications);
                [fileman release];
            }
        }

        if (RESULT) {
            if (RESULT == 4) {
                printf("  %s cannot be dumped with classdump-dyld.\n", image);
                exit(1);
            } else if (RESULT == 2) {
                printf("  %s does not implement any classes.\n", image);
                exit(1);
            } else if (RESULT == 3) {
                exit(1);
            } else {
                if (writeToDisk) {
                    printf("  Done. Check \"%s\" directory.\n", [inoutputDir UTF8String]);
                }
            }
        }
    }

    exit(0);
}
