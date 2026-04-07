#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes a block and catches any Objective-C NSException.
/// Returns nil on success, or the exception's reason string on failure.
FOUNDATION_EXPORT NSString * _Nullable catchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void));

/// Disable quiescence (idle) waiting on an XCUIApplication using ObjC runtime.
FOUNDATION_EXPORT void disableQuiescenceWait(id application);

NS_ASSUME_NONNULL_END
