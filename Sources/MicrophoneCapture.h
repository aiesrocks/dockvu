#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const MicrophoneCaptureErrorDomain;

typedef NS_ERROR_ENUM(MicrophoneCaptureErrorDomain, MicrophoneCaptureErrorCode) {
    MicrophoneCaptureErrorCodeObjectiveCException = 1,
};

typedef void (^MicrophoneCaptureLevelHandler)(float level);
typedef void (^MicrophoneCaptureConfigurationChangeHandler)(void);

/// Owns the AVAudioEngine exception boundary for microphone capture.
///
/// Swift imports startWithLevelHandler:configurationChangeHandler:error: as
/// start(levelHandler:configurationChangeHandler:) throws.
@interface MicrophoneCapture : NSObject

@property(nonatomic, readonly) AudioObjectID deviceID;

- (BOOL)startWithLevelHandler:(MicrophoneCaptureLevelHandler)levelHandler
    configurationChangeHandler:(MicrophoneCaptureConfigurationChangeHandler)configurationChangeHandler
                         error:(NSError * _Nullable * _Nullable)error;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
