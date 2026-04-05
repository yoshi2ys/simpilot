#import "ObjCExceptionCatcher.h"

NSString * _Nullable catchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"];
    }
}
