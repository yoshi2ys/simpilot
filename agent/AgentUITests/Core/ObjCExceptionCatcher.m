#import "ObjCExceptionCatcher.h"
#import <objc/runtime.h>

NSString * _Nullable catchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"];
    }
}

static SEL setterForProperty(NSString *key) {
    NSString *name = [key hasPrefix:@"_"] ? [key substringFromIndex:1] : key;
    return NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
        [[name substringToIndex:1] uppercaseString],
        [name substringFromIndex:1]]);
}

void disableQuiescenceWait(id application) {
    NSArray<NSString *> *candidates = @[
        @"idleAnimationWaitEnabled",      // Xcode 26+
        @"_shouldWaitForQuiescence",
        @"shouldWaitForQuiescence",
    ];
    for (NSString *key in candidates) {
        SEL setter = setterForProperty(key);
        if ([application respondsToSelector:setter]) {
            NSMethodSignature *sig = [application methodSignatureForSelector:setter];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:setter];
            BOOL val = NO;
            [inv setArgument:&val atIndex:2];
            [inv invokeWithTarget:application];
            return;
        }
    }
}
