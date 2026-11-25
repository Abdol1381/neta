#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised (nil if none). AVAudioEngine reports
/// many failures as NSExceptions, which Swift cannot catch and which would otherwise crash the app.
NSException * _Nullable SBTryObjC(void (NS_NOESCAPE ^block)(void));

/// Installs a handler that writes an uncaught exception to the diagnostics file before the app dies.
void SBInstallCrashLogger(NSString *path);

NS_ASSUME_NONNULL_END
