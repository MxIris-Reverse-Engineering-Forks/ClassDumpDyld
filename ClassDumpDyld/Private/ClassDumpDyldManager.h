#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, ClassDumpDyldArch) {
    ClassDumpDyldArchCurrent,
    ClassDumpDyldArchARM64e,
    ClassDumpDyldArchX86_64,
};

@interface ClassDumpDyldManager : NSObject
@property (nonatomic, strong, class, readonly) ClassDumpDyldManager *sharedManager;
@property (nonatomic, strong, readonly) NSSet<NSString *> *forbiddenClasses;
@property (nonatomic, strong, readonly) NSSet<NSString *> *forbiddenPaths;
@property (nonatomic) BOOL addHeadersFolder;
@property (nonatomic, assign, getter=isRecursive) BOOL recursive;
@property (nonatomic, assign, getter=isDebug) BOOL debug;
+ (instancetype)alloc NS_UNAVAILABLE;
+ (instancetype)allocWithZone:(struct _NSZone *)zone NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (id)copy NS_UNAVAILABLE;
- (id)mutableCopy NS_UNAVAILABLE;
- (void)addForbiddenClasses:(NSSet<NSString *> *)classes;
- (void)addForbiddenPaths:(NSSet<NSString *> *)paths;
- (void)allImagesWithCompletion:(void(^)(NSArray<NSString *> * _Nullable allImages, NSError * _Nullable error))completion;
- (void)dumpImageHeaders:(NSString *)image toPath:(NSString *)outputPath completion:(void(^ _Nullable)(NSError * _Nullable error))completion;
- (void)dumpAllImageHeadersToPath:(NSString *)outputPath completion:(void (^ _Nullable)(void))completion;
- (NSString *)dyldSharedCachePathForArch:(ClassDumpDyldArch)arch;
@end

NS_ASSUME_NONNULL_END
