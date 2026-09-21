#import "MicrophoneCapture.h"

#import <AudioToolbox/AudioToolbox.h>
#import <math.h>

NSErrorDomain const MicrophoneCaptureErrorDomain = @"app.dockvu.microphone-capture";

@interface MicrophoneCapture ()
@property(nonatomic, strong, nullable) AVAudioEngine *engine;
@property(nonatomic, strong, nullable) AVAudioInputNode *inputNode;
@property(nonatomic, strong, nullable) id configurationObserver;
@property(nonatomic, copy, nullable) MicrophoneCaptureLevelHandler levelHandler;
@property(nonatomic, copy, nullable) MicrophoneCaptureConfigurationChangeHandler configurationChangeHandler;
@property(nonatomic) BOOL tapInstalled;
@property(nonatomic, readwrite) AudioObjectID deviceID;
@end

@implementation MicrophoneCapture

- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceID = kAudioObjectUnknown;
    }
    return self;
}

// Deliberately internal and overridable so the exception boundary can be tested with a fake
// engine without adding injection surface to the production API.
- (AVAudioEngine *)makeEngine {
    return [[AVAudioEngine alloc] init];
}

static NSError *MicrophoneCaptureErrorFromException(NSException *exception) {
    NSString *reason = exception.reason ?: @"AVAudioEngine raised an Objective-C exception";
    return [NSError errorWithDomain:MicrophoneCaptureErrorDomain
                               code:MicrophoneCaptureErrorCodeObjectiveCException
                           userInfo:@{
                               NSLocalizedDescriptionKey: reason,
                               @"exceptionName": exception.name ?: @"NSException"
                           }];
}

static float MicrophoneCapturePeak(AVAudioPCMBuffer *buffer) {
    AVAudioFormat *format = buffer.format;
    if (format.commonFormat != AVAudioPCMFormatFloat32) {
        return 0.0f;
    }

    AVAudioFrameCount frameCount = buffer.frameLength;
    AVAudioChannelCount channelCount = format.channelCount;
    float *const _Nonnull * _Nullable channels = buffer.floatChannelData;
    if (frameCount == 0 || channelCount == 0 || channels == NULL) {
        return 0.0f;
    }

    float peak = 0.0f;
    if (format.interleaved) {
        float *samples = channels[0];
        if (samples == NULL) {
            return 0.0f;
        }
        NSUInteger sampleCount = (NSUInteger)frameCount * (NSUInteger)channelCount;
        for (NSUInteger index = 0; index < sampleCount; index++) {
            float magnitude = fabsf(samples[index]);
            if (isfinite(magnitude) && magnitude > peak) {
                peak = magnitude;
            }
        }
    } else {
        NSUInteger stride = MAX((NSUInteger)buffer.stride, (NSUInteger)1);
        for (AVAudioChannelCount channel = 0; channel < channelCount; channel++) {
            float *samples = channels[channel];
            if (samples == NULL) {
                continue;
            }
            for (AVAudioFrameCount frame = 0; frame < frameCount; frame++) {
                float magnitude = fabsf(samples[(NSUInteger)frame * stride]);
                if (isfinite(magnitude) && magnitude > peak) {
                    peak = magnitude;
                }
            }
        }
    }
    return fminf(peak, 1.0f);
}

- (AudioObjectID)currentDeviceIDForInputNode:(AVAudioInputNode *)inputNode {
    AudioUnit audioUnit = inputNode.audioUnit;
    if (audioUnit == NULL) {
        return kAudioObjectUnknown;
    }

    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    OSStatus status = AudioUnitGetProperty(audioUnit,
                                           kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global,
                                           0,
                                           &deviceID,
                                           &size);
    return status == noErr ? deviceID : kAudioObjectUnknown;
}

- (BOOL)startWithLevelHandler:(MicrophoneCaptureLevelHandler)levelHandler
    configurationChangeHandler:(MicrophoneCaptureConfigurationChangeHandler)configurationChangeHandler
                         error:(NSError **)error {
    @synchronized (self) {
        if (error != NULL) {
            *error = nil;
        }
        if (self.engine != nil) {
            return YES;
        }

        @try {
            AVAudioEngine *engine = [self makeEngine];
            AVAudioInputNode *inputNode = engine.inputNode;
            self.engine = engine;
            self.inputNode = inputNode;
            self.levelHandler = [levelHandler copy];
            self.configurationChangeHandler = [configurationChangeHandler copy];

            MicrophoneCaptureConfigurationChangeHandler changeHandler =
                self.configurationChangeHandler;
            self.configurationObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:AVAudioEngineConfigurationChangeNotification
                            object:engine
                             queue:nil
                        usingBlock:^(__unused NSNotification *notification) {
                changeHandler();
            }];

            MicrophoneCaptureLevelHandler tapHandler = self.levelHandler;
            [inputNode installTapOnBus:0
                            bufferSize:1024
                                format:nil
                                 block:^(AVAudioPCMBuffer *buffer, __unused AVAudioTime *when) {
                tapHandler(MicrophoneCapturePeak(buffer));
            }];
            self.tapInstalled = YES;

            [engine prepare];
            NSError *startError = nil;
            if (![engine startAndReturnError:&startError]) {
                [self tearDownEngineIgnoringException];
                if (error != NULL) {
                    *error = startError ?: [NSError errorWithDomain:MicrophoneCaptureErrorDomain
                                                               code:MicrophoneCaptureErrorCodeObjectiveCException
                                                           userInfo:@{NSLocalizedDescriptionKey: @"AVAudioEngine failed to start"}];
                }
                return NO;
            }
            self.deviceID = [self currentDeviceIDForInputNode:inputNode];
            return YES;
        } @catch (NSException *exception) {
            [self tearDownEngineIgnoringException];
            if (error != NULL) {
                *error = MicrophoneCaptureErrorFromException(exception);
            }
            return NO;
        }
    }
}

- (void)stop {
    @synchronized (self) {
        @try {
            [self tearDownEngine];
        } @catch (NSException *exception) {
            NSError *error = MicrophoneCaptureErrorFromException(exception);
            NSLog(@"Microphone teardown failed: %@", error.localizedDescription);
        }
    }
}

- (void)clearStateAndReturnEngine:(AVAudioEngine * _Nullable * _Nonnull)engine
                        inputNode:(AVAudioInputNode * _Nullable * _Nonnull)inputNode
                     hadInstalled:(BOOL *)hadInstalled {
    if (self.configurationObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.configurationObserver];
        self.configurationObserver = nil;
    }

    *engine = self.engine;
    *inputNode = self.inputNode;
    *hadInstalled = self.tapInstalled;
    self.engine = nil;
    self.inputNode = nil;
    self.tapInstalled = NO;
    self.levelHandler = nil;
    self.configurationChangeHandler = nil;
    self.deviceID = kAudioObjectUnknown;
}

- (void)tearDownEngine {
    AVAudioEngine *engine = nil;
    AVAudioInputNode *inputNode = nil;
    BOOL hadInstalled = NO;
    [self clearStateAndReturnEngine:&engine inputNode:&inputNode hadInstalled:&hadInstalled];
    if (engine == nil) {
        return;
    }
    @try {
        [engine stop];
    } @finally {
        if (hadInstalled) {
            [inputNode removeTapOnBus:0];
        }
    }
}

- (void)tearDownEngineIgnoringException {
    @try {
        [self tearDownEngine];
    } @catch (__unused NSException *exception) {
        // Preserve the setup exception/error. State and observer ownership were already cleared.
    }
}

- (void)dealloc {
    @synchronized (self) {
        [self tearDownEngineIgnoringException];
    }
}

@end
