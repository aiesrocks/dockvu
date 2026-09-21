#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import "../Sources/MicrophoneCapture.h"

@interface MicrophoneCapture (Testing)
- (AVAudioEngine *)makeEngine;
@end

typedef NS_ENUM(NSUInteger, FakeFailurePoint) {
    FakeFailurePointNone,
    FakeFailurePointInstall,
    FakeFailurePointPrepare,
    FakeFailurePointStart,
    FakeFailurePointStop,
    FakeFailurePointConfigurationWait,
};

@interface FakeInputNode : NSObject
@property(nonatomic) FakeFailurePoint failurePoint;
@property(nonatomic) BOOL installed;
@property(nonatomic) BOOL removed;
@property(nonatomic) double hardwareSampleRate;
@property(nonatomic, strong, nullable) AVAudioFormat *installedFormat;
@end

@implementation FakeInputNode
- (void)installTapOnBus:(AVAudioNodeBus)bus
             bufferSize:(AVAudioFrameCount)bufferSize
                 format:(AVAudioFormat *)format
                  block:(AVAudioNodeTapBlock)tapBlock {
    (void)bus;
    (void)bufferSize;
    (void)tapBlock;
    self.installedFormat = format;
    if (format != nil && self.hardwareSampleRate > 0 &&
        format.sampleRate != self.hardwareSampleRate) {
        @throw [NSException exceptionWithName:@"FakeFormatMismatchException"
                                       reason:@"stale explicit format does not match hardware"
                                     userInfo:nil];
    }
    if (self.failurePoint == FakeFailurePointInstall) {
        @throw [NSException exceptionWithName:@"FakeInstallException"
                                       reason:@"fake install failure"
                                     userInfo:nil];
    }
    self.installed = YES;
}

- (void)removeTapOnBus:(AVAudioNodeBus)bus {
    (void)bus;
    self.removed = YES;
}

- (AudioUnit)audioUnit {
    return NULL;
}
@end

@interface FakeAudioEngine : AVAudioEngine
@property(nonatomic, strong) FakeInputNode *fakeInput;
@property(nonatomic) FakeFailurePoint failurePoint;
@property(nonatomic) BOOL stopped;
@property(nonatomic, strong, nullable) dispatch_semaphore_t configurationSemaphore;
@end

@implementation FakeAudioEngine
- (instancetype)initWithFailurePoint:(FakeFailurePoint)failurePoint {
    self = [super init];
    if (self) {
        _failurePoint = failurePoint;
        _fakeInput = [[FakeInputNode alloc] init];
        _fakeInput.failurePoint = failurePoint;
        _fakeInput.hardwareSampleRate = 48000.0;
    }
    return self;
}

- (AVAudioInputNode *)inputNode {
    return (AVAudioInputNode *)self.fakeInput;
}

- (void)prepare {
    if (self.failurePoint == FakeFailurePointConfigurationWait) {
        self.configurationSemaphore = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:AVAudioEngineConfigurationChangeNotification
                              object:self];
        });
        if (dispatch_semaphore_wait(self.configurationSemaphore,
                                    dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) {
            @throw [NSException exceptionWithName:@"FakeConfigurationDeadlockException"
                                           reason:@"configuration callback could not run during prepare"
                                         userInfo:nil];
        }
    }
    if (self.failurePoint == FakeFailurePointPrepare) {
        @throw [NSException exceptionWithName:@"FakePrepareException"
                                       reason:@"fake prepare failure"
                                     userInfo:nil];
    }
}

- (BOOL)startAndReturnError:(NSError **)outError {
    (void)outError;
    if (self.failurePoint == FakeFailurePointStart) {
        @throw [NSException exceptionWithName:@"FakeStartException"
                                       reason:@"fake start failure"
                                     userInfo:nil];
    }
    return YES;
}

- (void)stop {
    self.stopped = YES;
    if (self.failurePoint == FakeFailurePointStop) {
        @throw [NSException exceptionWithName:@"FakeStopException"
                                       reason:@"fake stop failure"
                                     userInfo:nil];
    }
}
@end

@interface TestMicrophoneCapture : MicrophoneCapture
@property(nonatomic, copy) NSArray<NSNumber *> *failurePoints;
@property(nonatomic) NSUInteger factoryCalls;
@property(nonatomic, strong) NSMutableArray<FakeAudioEngine *> *engines;
@end

@implementation TestMicrophoneCapture
- (instancetype)initWithFailurePoints:(NSArray<NSNumber *> *)failurePoints {
    self = [super init];
    if (self) {
        _failurePoints = [failurePoints copy];
        _engines = [NSMutableArray array];
    }
    return self;
}

- (AVAudioEngine *)makeEngine {
    FakeFailurePoint point = FakeFailurePointNone;
    if (self.factoryCalls < self.failurePoints.count) {
        point = (FakeFailurePoint)self.failurePoints[self.factoryCalls].unsignedIntegerValue;
    }
    self.factoryCalls += 1;
    FakeAudioEngine *engine = [[FakeAudioEngine alloc] initWithFailurePoint:point];
    [self.engines addObject:engine];
    return engine;
}
@end

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSError *Start(TestMicrophoneCapture *capture) {
    NSError *error = nil;
    BOOL started = [capture startWithLevelHandler:^(__unused float level) {}
                       configurationChangeHandler:^{}
                                                error:&error];
    Require(started == (error == nil), @"start result and error must agree");
    return error;
}

static void TestExceptionBoundary(FakeFailurePoint point, NSString *reason) {
    TestMicrophoneCapture *capture = [[TestMicrophoneCapture alloc]
        initWithFailurePoints:@[@(point)]];
    NSError *error = Start(capture);
    Require(error != nil, @"Objective-C exception must become NSError");
    Require([error.domain isEqualToString:MicrophoneCaptureErrorDomain], @"wrong error domain");
    Require(error.code == MicrophoneCaptureErrorCodeObjectiveCException, @"wrong error code");
    Require([error.localizedDescription isEqualToString:reason], @"exception reason was not preserved");
    Require(capture.deviceID == kAudioObjectUnknown, @"failed capture must clear device ID");
}

static void TestNativeFormatAndFreshEngine(void) {
    TestMicrophoneCapture *capture = [[TestMicrophoneCapture alloc]
        initWithFailurePoints:@[@(FakeFailurePointNone), @(FakeFailurePointNone)]];
    Require(Start(capture) == nil, @"first start failed");
    FakeAudioEngine *first = capture.engines.lastObject;
    Require(first.fakeInput.installed, @"tap was not installed");
    Require(first.fakeInput.installedFormat == nil, @"tap must use the current native format");
    [capture stop];
    Require(first.stopped && first.fakeInput.removed, @"first engine was not torn down");

    Require(Start(capture) == nil, @"second start failed");
    FakeAudioEngine *second = capture.engines.lastObject;
    Require(capture.factoryCalls == 2, @"restart must create a fresh engine");
    Require(first != second, @"restart reused the previous engine");
    Require(second.fakeInput.installedFormat == nil, @"restart tap must still use native format");
    [capture stop];
}

static void TestStaleExplicitFormatControl(void) {
    FakeInputNode *input = [[FakeInputNode alloc] init];
    input.hardwareSampleRate = 48000.0;
    AVAudioFormat *staleFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                                              channels:1];
    BOOL mismatchRaised = NO;
    @try {
        [input installTapOnBus:0 bufferSize:1024 format:staleFormat block:^(__unused AVAudioPCMBuffer *buffer,
                                                                          __unused AVAudioTime *when) {}];
    } @catch (NSException *exception) {
        mismatchRaised = [exception.name isEqualToString:@"FakeFormatMismatchException"];
    }
    Require(mismatchRaised, @"control must reproduce a stale explicit-format mismatch");

    TestMicrophoneCapture *capture = [[TestMicrophoneCapture alloc]
        initWithFailurePoints:@[@(FakeFailurePointNone)]];
    Require(Start(capture) == nil, @"native-format boundary start failed");
    Require(capture.engines.lastObject.fakeInput.installedFormat == nil,
            @"boundary passed the stale format instead of selecting current hardware format");
    [capture stop];
}

static void TestTimerContinuesAfterInstallException(void) {
    TestMicrophoneCapture *capture = [[TestMicrophoneCapture alloc]
        initWithFailurePoints:@[@(FakeFailurePointInstall), @(FakeFailurePointNone)]];
    __block NSUInteger callbacks = 0;
    __block BOOL firstExceptionTrapped = NO;
    __block BOOL secondStartSucceeded = NO;
    __block NSTimer *timer = nil;
    timer = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(__unused NSTimer *firedTimer) {
        callbacks += 1;
        NSError *error = Start(capture);
        if (callbacks == 1) {
            firstExceptionTrapped = error != nil;
        } else if (callbacks == 2) {
            secondStartSucceeded = error == nil;
            [capture stop];
            [timer invalidate];
        }
    }];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (callbacks < 2 && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    [timer invalidate];
    Require(callbacks >= 2, @"repeating timer stopped after trapped install exception");
    Require(firstExceptionTrapped, @"first timer callback did not trap install exception");
    Require(secondStartSucceeded, @"next timer callback did not start a fresh engine");
    Require(capture.factoryCalls == 2, @"timer retry did not create exactly two fresh engines");
}

static void TestStopExceptionIsContained(void) {
    TestMicrophoneCapture *capture = [[TestMicrophoneCapture alloc]
        initWithFailurePoints:@[@(FakeFailurePointStop), @(FakeFailurePointNone)]];
    Require(Start(capture) == nil, @"start before stop exception failed");
    @try {
        [capture stop];
    } @catch (__unused NSException *exception) {
        Require(NO, @"stop exception crossed the Objective-C boundary");
    }
    Require(capture.deviceID == kAudioObjectUnknown, @"stop exception must still clear state");
    Require(Start(capture) == nil, @"capture could not restart after stop exception");
    Require(capture.factoryCalls == 2, @"restart after stop exception must use a fresh engine");
    [capture stop];
}

static void TestConfigurationCallbackDoesNotTakeControlLock(void) {
    TestMicrophoneCapture *capture = [[TestMicrophoneCapture alloc]
        initWithFailurePoints:@[@(FakeFailurePointConfigurationWait)]];
    __block BOOL callbackObserved = NO;
    NSError *error = nil;
    BOOL started = [capture startWithLevelHandler:^(__unused float level) {}
                       configurationChangeHandler:^{
                           callbackObserved = YES;
                           dispatch_semaphore_signal(capture.engines.lastObject.configurationSemaphore);
                       }
                                                error:&error];
    Require(started && error == nil, @"configuration callback deadlocked engine preparation");
    Require(callbackObserved, @"queue:nil configuration callback was not delivered");
    [capture stop];
}

int main(void) {
    @autoreleasepool {
        TestExceptionBoundary(FakeFailurePointInstall, @"fake install failure");
        TestExceptionBoundary(FakeFailurePointPrepare, @"fake prepare failure");
        TestExceptionBoundary(FakeFailurePointStart, @"fake start failure");
        TestNativeFormatAndFreshEngine();
        TestStaleExplicitFormatControl();
        TestTimerContinuesAfterInstallException();
        TestStopExceptionIsContained();
        TestConfigurationCallbackDoesNotTakeControlLock();
        NSLog(@"MicrophoneCaptureTests passed");
    }
    return 0;
}
