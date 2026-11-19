#import "RTCAudioShim.h"

RTCPeerConnectionFactory *DSFactoryWithAudioDevice(id<RTCAudioDevice> device) {
    return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:[[RTCDefaultVideoEncoderFactory alloc] init]
                                                     decoderFactory:[[RTCDefaultVideoDecoderFactory alloc] init]
                                                        audioDevice:device];
}
