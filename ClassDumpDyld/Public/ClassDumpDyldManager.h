#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ClassDumpDyldManager : NSObject
@property (nonatomic, strong, class, readonly) ClassDumpDyldManager *sharedManager;
@property (nonatomic, strong, readonly) NSSet<NSString *> *forbiddenClasses;
@property (nonatomic, strong, readonly) NSSet<NSString *> *forbiddenPaths;
@property (nonatomic, assign, getter=isRecursive) BOOL recursive;
@property (nonatomic, assign, getter=isDebug) BOOL debug;
+ (instancetype)alloc NS_UNAVAILABLE;
+ (instancetype)allocWithZone:(struct _NSZone *)zone NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (id)copy NS_UNAVAILABLE;
- (id)mutableCopy NS_UNAVAILABLE;
- (void)dumpHeadersToPath:(NSString *)outputPath;
- (void)addForbiddenClasses:(NSSet<NSString *> *)classes;
- (void)addForbiddenPaths:(NSSet<NSString *> *)paths;
@end

NS_ASSUME_NONNULL_END
