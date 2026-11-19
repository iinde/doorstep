// The WebRTC build ships its custom audio device support on macOS but leaves the header out.
// These declarations match sdk/objc/components/audio/RTCAudioDevice.h (WebRTC M125, BSD).
#import <AudioUnit/AudioUnit.h>
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

typedef OSStatus (^RTCAudioDeviceGetPlayoutDataBlock)(
    AudioUnitRenderActionFlags *_Nonnull actionFlags, const AudioTimeStamp *_Nonnull timestamp,
    NSInteger inputBusNumber, UInt32 frameCount, AudioBufferList *_Nonnull outputData);

typedef OSStatus (^RTCAudioDeviceRenderRecordedDataBlock)(
    AudioUnitRenderActionFlags *_Nonnull actionFlags, const AudioTimeStamp *_Nonnull timestamp,
    NSInteger inputBusNumber, UInt32 frameCount, AudioBufferList *_Nonnull inputData,
    void *_Nullable renderContext);

typedef OSStatus (^RTCAudioDeviceDeliverRecordedDataBlock)(
    AudioUnitRenderActionFlags *_Nonnull actionFlags, const AudioTimeStamp *_Nonnull timestamp,
    NSInteger inputBusNumber, UInt32 frameCount, const AudioBufferList *_Nullable inputData,
    void *_Nullable renderContext,
    NS_NOESCAPE RTCAudioDeviceRenderRecordedDataBlock _Nullable renderBlock);

@protocol RTCAudioDeviceDelegate <NSObject>
@property(readonly, nonnull) RTCAudioDeviceDeliverRecordedDataBlock deliverRecordedData;
@property(readonly) double preferredInputSampleRate;
@property(readonly) NSTimeInterval preferredInputIOBufferDuration;
@property(readonly) double preferredOutputSampleRate;
@property(readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property(readonly, nonnull) RTCAudioDeviceGetPlayoutDataBlock getPlayoutData;
- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
- (void)dispatchAsync:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;
@end

@protocol RTCAudioDevice <NSObject>
@property(readonly) double deviceInputSampleRate;
@property(readonly) NSTimeInterval inputIOBufferDuration;
@property(readonly) NSInteger inputNumberOfChannels;
@property(readonly) NSTimeInterval inputLatency;
@property(readonly) double deviceOutputSampleRate;
@property(readonly) NSTimeInterval outputIOBufferDuration;
@property(readonly) NSInteger outputNumberOfChannels;
@property(readonly) NSTimeInterval outputLatency;
@property(readonly) BOOL isInitialized;
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate;
- (BOOL)terminateDevice;
@property(readonly) BOOL isPlayoutInitialized;
- (BOOL)initializePlayout;
@property(readonly) BOOL isPlaying;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;
@property(readonly) BOOL isRecordingInitialized;
- (BOOL)initializeRecording;
@property(readonly) BOOL isRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;
@end

/// A WebRTC factory whose audio comes from `device` instead of the microphone.
RTCPeerConnectionFactory *DSFactoryWithAudioDevice(id<RTCAudioDevice> device);

NS_ASSUME_NONNULL_END
