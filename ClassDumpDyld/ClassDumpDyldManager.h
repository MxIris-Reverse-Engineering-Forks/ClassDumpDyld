//
//  ClassDumpDyldManager.h
//  ClassDumpDyld
//
//  Created by JH on 2024/1/26.
//

#import <Foundation/Foundation.h>
#import "Singleton.h"

#include <dirent.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/nlist.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

NS_ASSUME_NONNULL_BEGIN

@interface ClassDumpDyldManager : NSObject
SingletonInterface(ClassDumpDyldManager, sharedManager)
@property (nonatomic, strong, readonly) NSSet<NSString *> *forbiddenClasses;
@property (nonatomic, strong, readonly) NSSet<NSString *> *forbiddenPaths;
@property (nonatomic, assign, getter=isRecursive) BOOL recursive;
@property (nonatomic, assign, getter=isDebug) BOOL debug;
@end

NS_ASSUME_NONNULL_END
