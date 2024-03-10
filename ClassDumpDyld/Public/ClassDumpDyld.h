#import <Foundation/Foundation.h>

//! Project version number for ClassDumpDyld.
FOUNDATION_EXPORT double ClassDumpDyldVersionNumber;

//! Project version string for ClassDumpDyld.
FOUNDATION_EXPORT const unsigned char ClassDumpDyldVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <ClassDumpDyld/PublicHeader.h>

#if SWIFT_PACKAGE
#import "../Private/ClassDumpDyldManager.h"
#else
#import <ClassDumpDyld/ClassDumpDyldManager.h>
#endif
