#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes a block and catches any Objective-C NSException.
/// Returns nil on success, or the exception's reason string on failure.
FOUNDATION_EXPORT NSString * _Nullable catchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
