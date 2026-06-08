#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>

#define ytmuBool(key) [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"][key] boolValue]

static BOOL autoRemixEnabled(void) {
    return ytmuBool(@"YTMUltimateIsEnabled") && ytmuBool(@"autoRemix");
}

// Per-tap DSP state
typedef struct {
    float reverbBuf[8192];
    int   reverbIdx;
    float prevL;
    float prevR;
} RemixContext;

static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    RemixContext *ctx = (RemixContext *)calloc(1, sizeof(RemixContext));
    *tapStorageOut = ctx;
}

static void tapFinalize(MTAudioProcessingTapRef tap) {
    RemixContext *ctx = (RemixContext *)MTAudioProcessingTapGetStorage(tap);
    free(ctx);
}

static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *fmt) {}
static void tapUnprepare(MTAudioProcessingTapRef tap) {}

static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames, MTAudioProcessingTapFlags flags,
                       AudioBufferList *bufferListInOut, CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (status != noErr || !autoRemixEnabled()) return;

    RemixContext *ctx = (RemixContext *)MTAudioProcessingTapGetStorage(tap);

    // Reverb parameters: ~93 ms delay at 44.1 kHz
    const int   kDelay     = 4096;
    const float kDecay     = 0.50f;
    const float kWetMix    = 0.28f;
    const float kDryMix    = 0.80f;
    // Mild high-pass to tighten bass after saturation
    const float kHPAlpha   = 0.92f;

    for (UInt32 b = 0; b < bufferListInOut->mNumberBuffers; b++) {
        float *s      = (float *)bufferListInOut->mBuffers[b].mData;
        UInt32 frames = bufferListInOut->mBuffers[b].mDataByteSize / sizeof(float);

        // Interleaved stereo or mono: treat as one stream of samples
        float *prev = (b == 0) ? &ctx->prevL : &ctx->prevR;

        for (UInt32 i = 0; i < frames; i++) {
            float dry = s[i];

            // Read reverb tail
            int readIdx = ((ctx->reverbIdx - kDelay) + 8192) % 8192;
            float tail  = ctx->reverbBuf[readIdx];

            // Write new reverb sample
            ctx->reverbBuf[ctx->reverbIdx] = (dry + tail) * kDecay;
            ctx->reverbIdx = (ctx->reverbIdx + 1) % 8192;

            float wet = dry * kDryMix + tail * kWetMix;

            // Soft saturation (tape-style warmth)
            if      (wet >  0.85f) wet =  0.85f + (wet -  0.85f) * 0.15f;
            else if (wet < -0.85f) wet = -0.85f + (wet + 0.85f) * 0.15f;

            // DC-blocking high-pass
            float out = wet - *prev + kHPAlpha * (i > 0 ? s[i - 1] - wet + *prev : 0.0f);
            *prev = wet;
            s[i]  = out;
        }
    }
}

static void installRemixTap(AVPlayerItem *item) {
    if (!item || !autoRemixEnabled()) return;

    AVPlayerItemTrack *audioTrack = nil;
    for (AVPlayerItemTrack *track in item.tracks) {
        if ([track.assetTrack.mediaType isEqualToString:AVMediaTypeAudio]) {
            audioTrack = track;
            break;
        }
    }
    if (!audioTrack || !audioTrack.assetTrack) return;

    MTAudioProcessingTapCallbacks cb = {
        .version    = kMTAudioProcessingTapCallbacksVersion_0,
        .clientInfo = NULL,
        .init       = tapInit,
        .finalize   = tapFinalize,
        .prepare    = tapPrepare,
        .unprepare  = tapUnprepare,
        .process    = tapProcess
    };

    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) != noErr) return;

    AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack.assetTrack];
    params.audioTapProcessor = tap;
    CFRelease(tap);

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[params];
    item.audioMix = mix;
}

%hook AVPlayer

- (void)play {
    %orig;
    if (!autoRemixEnabled()) return;

    AVPlayerItem *item = self.currentItem;
    if (!item) return;

    if (item.tracks.count > 0) {
        installRemixTap(item);
    } else {
        // Tracks not yet loaded (common with HLS); wait briefly
        __weak AVPlayerItem *weakItem = item;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installRemixTap(weakItem);
        });
    }
}

- (void)setCurrentItem:(AVPlayerItem *)currentItem {
    %orig;
    if (!currentItem || !autoRemixEnabled()) return;

    // Observe until the item has tracks available
    __weak AVPlayerItem *weakItem = currentItem;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installRemixTap(weakItem);
    });
}

%end
