#ifndef Singleton_h
#define Singleton_h

#define SingletonInterface(ClassName, ShareName) @property (nonatomic, strong, class, readonly) ClassName *ShareName;

#define SingletonImplementation(ClassName, ShareName) static ClassName *_instance = nil;\
+ (instancetype)allocWithZone:(struct _NSZone *)zone{\
    static dispatch_once_t onceToken;\
    dispatch_once(&onceToken, ^{\
        _instance = [super allocWithZone:zone];\
    });\
    return _instance;\
}\
+ (ClassName *)ShareName{\
    return [self new];\
}\
- (nonnull id)copyWithZone:(nullable NSZone *)zone {\
    return _instance;\
}\
- (nonnull id)mutableCopyWithZone:(nullable NSZone *)zone {\
    return _instance;\
}

#endif /* Singleton_h */
