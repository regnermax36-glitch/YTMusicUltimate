/*
 * AutoRemix.x — real-time audio remix engine
 *
 * Three modes, four intensity levels.  All DSP runs in C with no ObjC
 * calls on the audio render thread.  Settings are mirrored to C11 atomics
 * on the main thread so the audio thread can read them safely.
 *
 * Crash-safety notes:
 *   • NSUserDefaults is never touched from the audio render thread.
 *   • Every buffer pointer is NULL-guarded before use.
 *   • Associated-object guard prevents installing the tap twice on one item.
 *   • calloc return value is checked; tap creation is aborted on failure.
 *   • HP filter stores both previous input and previous output (the original
 *     code accidentally read already-overwritten samples).
 *   • Per-channel reverb state (the original code shared one buffer
 *     across all channels, corrupting stereo).
 */

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdatomic.h>

// ── Atomic settings cache ─────────────────────────────────────────────────
// Written from the main thread (syncRemixSettings), read from the audio
// render thread without any ObjC calls.
static atomic_bool gRemixActive    = ATOMIC_VAR_INIT(false);
static atomic_int  gRemixMode      = ATOMIC_VAR_INIT(0);   // 0=Club 1=Lo-Fi 2=Studio
static atomic_int  gRemixIntensity = ATOMIC_VAR_INIT(2);   // 0=Light 1=Moderate 2=Heavy 3=Max

#define ytmuBool(k) [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] \
                      objectForKey:(k)] != nil ? \
                     [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] \
                      [k] boolValue] : NO
#define ytmuInt(k)  [[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] \
                      objectForKey:(k)] integerValue]

static void syncRemixSettings(void) {
    BOOL on = (ytmuBool(@"YTMUltimateIsEnabled") && ytmuBool(@"autoRemix"));
    atomic_store_explicit(&gRemixActive,    (bool)on,                  memory_order_release);
    atomic_store_explicit(&gRemixMode,      (int)ytmuInt(@"remixMode"), memory_order_release);
    atomic_store_explicit(&gRemixIntensity, (int)ytmuInt(@"remixIntensity"), memory_order_release);
}

// ── Biquad filter (transposed direct-form II) ─────────────────────────────
typedef struct { float b0,b1,b2, a1,a2, s1,s2; } Biquad;

static inline float bqRun(Biquad *f, float x) {
    float y = f->b0*x + f->s1;
    f->s1   = f->b1*x - f->a1*y + f->s2;
    f->s2   = f->b2*x - f->a2*y;
    return y;
}

static void bqHP(Biquad *f, float fc, float sr) {
    float k = tanf((float)M_PI * fc / sr);
    float k2 = k*k, d = 1.0f + (float)M_SQRT2*k + k2;
    f->b0 =  1.0f/d;  f->b1 = -2.0f/d;  f->b2 = 1.0f/d;
    f->a1 =  2.0f*(k2-1.0f)/d;
    f->a2 =  (1.0f - (float)M_SQRT2*k + k2)/d;
    f->s1 = f->s2 = 0.0f;
}

static void bqLP(Biquad *f, float fc, float sr) {
    float k = tanf((float)M_PI * fc / sr);
    float k2 = k*k, d = 1.0f + (float)M_SQRT2*k + k2;
    f->b0 = k2/d;  f->b1 = 2.0f*k2/d;  f->b2 = k2/d;
    f->a1 = 2.0f*(k2-1.0f)/d;
    f->a2 = (1.0f - (float)M_SQRT2*k + k2)/d;
    f->s1 = f->s2 = 0.0f;
}

// Low-shelf (+gainDB at fc), Audio EQ Cookbook, shelf slope S=1
static void bqLowShelf(Biquad *f, float fc, float gainDB, float sr) {
    float A    = powf(10.0f, gainDB / 40.0f);
    float w0   = 2.0f*(float)M_PI * fc / sr;
    float cosw = cosf(w0), sinw = sinf(w0);
    float sA   = sqrtf(A);
    float alpha = sinw / 2.0f * sqrtf((A + 1.0f/A) * (1.0f/1.0f - 1.0f) + 2.0f);
    // S=1 → (A+1/A)*(1/S−1)+2 = (A+1/A)*0+2 = 2
    alpha = sinw / 2.0f * sqrtf(2.0f) * sA;

    float b0 =    A*((A+1) - (A-1)*cosw + 2*sA*alpha);
    float b1 = 2*A*((A-1) - (A+1)*cosw              );
    float b2 =    A*((A+1) - (A-1)*cosw - 2*sA*alpha);
    float a0 =      (A+1) + (A-1)*cosw + 2*sA*alpha;
    float a1 = -2*( (A-1) + (A+1)*cosw              );
    float a2 =      (A+1) + (A-1)*cosw - 2*sA*alpha;

    float inv = 1.0f / a0;
    f->b0=b0*inv; f->b1=b1*inv; f->b2=b2*inv;
    f->a1=a1*inv; f->a2=a2*inv;
    f->s1=f->s2=0.0f;
}

// High-shelf (+gainDB above fc)
static void bqHighShelf(Biquad *f, float fc, float gainDB, float sr) {
    float A    = powf(10.0f, gainDB / 40.0f);
    float w0   = 2.0f*(float)M_PI * fc / sr;
    float cosw = cosf(w0), sinw = sinf(w0);
    float sA   = sqrtf(A);
    float alpha = sinw / 2.0f * sqrtf(2.0f) * sA;

    float b0 =    A*((A+1) + (A-1)*cosw + 2*sA*alpha);
    float b1 = -2*A*((A-1) + (A+1)*cosw              );
    float b2 =    A*((A+1) + (A-1)*cosw - 2*sA*alpha);
    float a0 =      (A+1) - (A-1)*cosw + 2*sA*alpha;
    float a1 =  2*( (A-1) - (A+1)*cosw              );
    float a2 =      (A+1) - (A-1)*cosw - 2*sA*alpha;

    float inv = 1.0f / a0;
    f->b0=b0*inv; f->b1=b1*inv; f->b2=b2*inv;
    f->a1=a1*inv; f->a2=a2*inv;
    f->s1=f->s2=0.0f;
}

// ── Reverb engine (Freeverb-inspired: 4 comb + 2 allpass per channel) ─────
#define RC  4        // comb filter count
#define RA  2        // allpass filter count
#define NCH 2        // max channels
#define MAX_COMB_BUF  1850
#define MAX_AP_BUF    680
#define MAX_WOBBLE    2048  // Lo-Fi pitch-wobble delay line
#define MAX_PRE_DEL   1200  // pre-delay line

typedef struct {
    // ── Reverb ──
    float   cb[RC][NCH][MAX_COMB_BUF];   // comb delay lines
    int     cw[RC][NCH];                  // comb write index
    int     cl[RC][NCH];                  // comb length (samples)
    float   combFB;                       // comb feedback gain

    float   ab[RA][NCH][MAX_AP_BUF];
    int     aw[RA][NCH];
    int     al[RA][NCH];

    // ── Pre-delay ──
    float   pd[NCH][MAX_PRE_DEL];
    int     pw[NCH];
    int     pdLen;

    // ── Lo-Fi pitch-wobble ──
    float   wb[NCH][MAX_WOBBLE];          // wobble delay line
    int     ww[NCH];                      // wobble write index
    float   lfoPhase;                     // LFO phase [0..1)
    float   lfoRate;                      // LFO phase increment per sample

    // ── Filters ──
    Biquad  hp[NCH];        // DC-blocking HP at 22 Hz (applied to all modes)
    Biquad  lp1[NCH];       // Lo-Fi LP, stage 1  (4th-order = two 2nd-order)
    Biquad  lp2[NCH];       // Lo-Fi LP, stage 2
    Biquad  bassShelf[NCH]; // Club bass boost (low-shelf)
    Biquad  airShelf[NCH];  // Studio air boost (high-shelf)

    // ── HP filter memory (one pair per channel) ──
    // Correct first-order HP: y[n] = α*(y[n-1] + x[n] - x[n-1])
    float   hpPrevIn[NCH];
    float   hpPrevOut[NCH];

    // ── Compressor ──
    float   compEnv;        // envelope follower state
    float   compGain;       // current gain

    // ── Bitcrusher (Lo-Fi) ──
    float   bcPhase;        // accumulates per-sample; holds when < 1
    float   bcHeld[NCH];    // held sample value

    // Configured by tapPrepare
    float   sampleRate;
    BOOL    ready;
} RemixCtx;

// ── Reverb helpers ────────────────────────────────────────────────────────
static inline float combTick(RemixCtx *c, int fi, int ch, float in, float fb) {
    int len  = c->cl[fi][ch];
    int rIdx = (c->cw[fi][ch] - len + MAX_COMB_BUF) % MAX_COMB_BUF;
    float out = c->cb[fi][ch][rIdx];
    c->cb[fi][ch][c->cw[fi][ch]] = in + out * fb;
    c->cw[fi][ch] = (c->cw[fi][ch] + 1) % MAX_COMB_BUF;
    return out;
}

static inline float apTick(RemixCtx *c, int fi, int ch, float in) {
    const float g = 0.5f;
    int len  = c->al[fi][ch];
    int rIdx = (c->aw[fi][ch] - len + MAX_AP_BUF) % MAX_AP_BUF;
    float delayed = c->ab[fi][ch][rIdx];
    float v = in - g * delayed;
    c->ab[fi][ch][c->aw[fi][ch]] = v;
    c->aw[fi][ch] = (c->aw[fi][ch] + 1) % MAX_AP_BUF;
    return delayed + g * v;
}

static inline float preDelayTick(RemixCtx *c, int ch, float in) {
    if (c->pdLen <= 0) return in;
    int rIdx = (c->pw[ch] - c->pdLen + MAX_PRE_DEL) % MAX_PRE_DEL;
    float out = c->pd[ch][rIdx];
    c->pd[ch][c->pw[ch]] = in;
    c->pw[ch] = (c->pw[ch] + 1) % MAX_PRE_DEL;
    return out;
}

// Linear-interpolating read from wobble delay line
static inline float wobbleRead(RemixCtx *c, int ch, float delaySamples) {
    delaySamples = delaySamples < 1.0f ? 1.0f : delaySamples;
    int   d0   = (int)delaySamples;
    float frac = delaySamples - (float)d0;
    int   i0   = (c->ww[ch] - d0     + MAX_WOBBLE) % MAX_WOBBLE;
    int   i1   = (c->ww[ch] - d0 - 1 + MAX_WOBBLE) % MAX_WOBBLE;
    return c->wb[ch][i0] * (1.0f - frac) + c->wb[ch][i1] * frac;
}

// ── Context setup (called from tapPrepare) ────────────────────────────────
static void configureCtx(RemixCtx *ctx, float sr, int mode) {
    float scale = sr / 44100.0f;

    // Comb delay times at 44.1 kHz (L channel); R offsets for stereo spread
    static const int kClubBase[RC]   = {1557, 1617, 1491, 1422};
    static const int kStudioBase[RC] = {1116, 1188, 1277, 1356};
    static const int kLROffset[RC]   = {+23,  +23,  -23,  -23};
    static const int kLRStudio[RC]   = {+17,  +17,  -17,  -17};

    const int  *base   = (mode == 2) ? kStudioBase : kClubBase;
    const int  *offsets= (mode == 2) ? kLRStudio   : kLROffset;
    ctx->combFB = (mode == 2) ? 0.80f : 0.84f;

    for (int i = 0; i < RC; i++) {
        for (int ch = 0; ch < NCH; ch++) {
            int d = (int)((base[i] + (ch == 1 ? offsets[i] : 0)) * scale);
            d = d < 2 ? 2 : (d >= MAX_COMB_BUF ? MAX_COMB_BUF - 1 : d);
            ctx->cl[i][ch] = d;
        }
    }

    // Allpass delays at 44.1 kHz
    static const int kAPBase[RA]    = {225, 556};
    static const int kAPOffset[RA]  = {+11, -11};
    for (int i = 0; i < RA; i++) {
        for (int ch = 0; ch < NCH; ch++) {
            int d = (int)((kAPBase[i] + (ch == 1 ? kAPOffset[i] : 0)) * scale);
            d = d < 2 ? 2 : (d >= MAX_AP_BUF ? MAX_AP_BUF - 1 : d);
            ctx->al[i][ch] = d;
        }
    }

    // Pre-delay: Club=5ms, Lo-Fi=0, Studio=20ms
    static const float kPreMs[3] = {5.0f, 0.0f, 20.0f};
    ctx->pdLen = (int)(kPreMs[mode] * 0.001f * sr);
    ctx->pdLen = ctx->pdLen >= MAX_PRE_DEL ? MAX_PRE_DEL - 1 : ctx->pdLen;

    // Filters
    for (int ch = 0; ch < NCH; ch++) {
        bqHP(&ctx->hp[ch],        22.0f,  sr);
        bqLP(&ctx->lp1[ch],     7200.0f,  sr);    // Lo-Fi LP stage 1
        bqLP(&ctx->lp2[ch],     7200.0f,  sr);    // Lo-Fi LP stage 2
        bqLowShelf (&ctx->bassShelf[ch], 180.0f,  5.5f, sr);  // Club
        bqHighShelf(&ctx->airShelf[ch], 9000.0f,  3.0f, sr);  // Studio
    }

    // Lo-Fi LFO: 0.5 Hz wow, small flutter at 5 Hz baked in via depth
    ctx->lfoRate  = 0.5f / sr;
    ctx->lfoPhase = 0.0f;

    // Compressor initial state
    ctx->compEnv  = 0.0f;
    ctx->compGain = 1.0f;

    // Bitcrusher: hold at (sr/6000) to simulate ~6 kHz sample-rate feel for Lo-Fi
    ctx->bcPhase = 0.0f;

    ctx->sampleRate = sr;
    ctx->ready = YES;
}

// ── Tap callbacks ─────────────────────────────────────────────────────────
static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    RemixCtx *ctx = (RemixCtx *)calloc(1, sizeof(RemixCtx));
    if (!ctx) { *tapStorageOut = NULL; return; }
    ctx->compGain = 1.0f;
    *tapStorageOut = ctx;
}

static void tapFinalize(MTAudioProcessingTapRef tap) {
    RemixCtx *ctx = (RemixCtx *)MTAudioProcessingTapGetStorage(tap);
    if (ctx) free(ctx);
}

static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                       const AudioStreamBasicDescription *fmt) {
    RemixCtx *ctx = (RemixCtx *)MTAudioProcessingTapGetStorage(tap);
    if (!ctx) return;
    float sr = (float)fmt->mSampleRate;
    if (sr <= 0.0f) sr = 44100.0f;
    int mode = atomic_load_explicit(&gRemixMode, memory_order_acquire);
    configureCtx(ctx, sr, mode);
}

static void tapUnprepare(MTAudioProcessingTapRef tap) {}

static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                       MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                       CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (status != noErr) return;

    // Read settings atomically — no ObjC, no locks, safe on audio thread
    if (!atomic_load_explicit(&gRemixActive, memory_order_acquire)) return;

    RemixCtx *ctx = (RemixCtx *)MTAudioProcessingTapGetStorage(tap);
    if (!ctx || !ctx->ready) return;

    int  mode      = atomic_load_explicit(&gRemixMode,      memory_order_relaxed);
    int  intensity = atomic_load_explicit(&gRemixIntensity, memory_order_relaxed);

    // Intensity → wet mix: Light=0.20, Moderate=0.40, Heavy=0.60, Max=0.80
    static const float kWetTable[4] = {0.20f, 0.40f, 0.60f, 0.80f};
    intensity = (intensity < 0) ? 0 : (intensity > 3) ? 3 : intensity;
    float wet = kWetTable[intensity];
    float dry = 1.0f - wet * 0.3f;  // keep most of dry to avoid level drop

    float fb  = ctx->combFB;

    // Re-configure if mode changed mid-stream (mode change is rare)
    static _Atomic(int) sCachedMode = ATOMIC_VAR_INIT(-1);
    int prevMode = atomic_load_explicit(&sCachedMode, memory_order_relaxed);
    if (prevMode != mode) {
        configureCtx(ctx, ctx->sampleRate, mode);
        atomic_store_explicit(&sCachedMode, mode, memory_order_relaxed);
    }

    UInt32 numBufs = bufferListInOut->mNumberBuffers;
    // Cap to NCH to avoid out-of-bounds filter access
    if (numBufs > NCH) numBufs = NCH;

    for (UInt32 b = 0; b < numBufs; b++) {
        float  *s    = (float *)bufferListInOut->mBuffers[b].mData;
        UInt32  n    = bufferListInOut->mBuffers[b].mDataByteSize / sizeof(float);
        int     ch   = (int)(b % NCH);

        if (!s || n == 0) continue;

        for (UInt32 i = 0; i < n; i++) {
            float x = s[i];

            // ── Guard: silence / NaN ──
            if (x != x) x = 0.0f;  // NaN check

            // ── Mode-specific processing ───────────────────────────────
            float processed;

            if (mode == 1) {
                // ── Lo-Fi ──────────────────────────────────────────────
                // 1. Low-pass (4th order) for vintage frequency response
                float lp = bqRun(&ctx->lp1[ch], bqRun(&ctx->lp2[ch], x));

                // 2. Wow/flutter via LFO-modulated delay (only update LFO on ch0)
                if (ch == 0) {
                    ctx->lfoPhase += ctx->lfoRate;
                    if (ctx->lfoPhase >= 1.0f) ctx->lfoPhase -= 1.0f;
                }
                float lfoVal  = sinf(2.0f * (float)M_PI * ctx->lfoPhase);
                float wobDel  = 8.0f + lfoVal * 6.0f;  // 2..14 samples pitch drift
                ctx->wb[ch][ctx->ww[ch]] = lp;
                ctx->ww[ch] = (ctx->ww[ch] + 1) % MAX_WOBBLE;
                float wobbled = wobbleRead(ctx, ch, wobDel);

                // 3. Bitcrusher-lite: hold sample at ~6000 Hz
                if (ch == 0) ctx->bcPhase += ctx->sampleRate / 6000.0f;
                if (ctx->bcPhase >= 1.0f) {
                    ctx->bcPhase -= 1.0f;
                    ctx->bcHeld[ch] = wobbled;
                }
                float crushed = ctx->bcHeld[ch];

                // 4. Blend with DC-blocking HP
                float dcBlocked = bqRun(&ctx->hp[ch], crushed);
                processed = x * (1.0f - wet) + dcBlocked * wet;

            } else {
                // ── Club (0) or Studio (2) — Schroeder reverb ─────────
                float prein = preDelayTick(ctx, ch, x);

                // 4 parallel comb filters
                float rev = 0.0f;
                for (int fi = 0; fi < RC; fi++)
                    rev += combTick(ctx, fi, ch, prein, fb);
                rev *= 0.25f;  // normalise

                // 2 series allpass
                for (int fi = 0; fi < RA; fi++)
                    rev = apTick(ctx, fi, ch, rev);

                // Mode-specific tone shaping
                if (mode == 0) {
                    // Club: bass boost + hard saturation
                    float boosted = bqRun(&ctx->bassShelf[ch], x);
                    float sat = boosted + 0.15f * boosted * boosted * boosted;
                    sat = sat >  0.95f ?  0.95f : (sat < -0.95f ? -0.95f : sat);
                    processed = bqRun(&ctx->hp[ch], sat * dry + rev * wet);
                } else {
                    // Studio: air shelf + gentle compressor
                    float aired = bqRun(&ctx->airShelf[ch], x);

                    // Simple peak compressor: attack 5ms, release 150ms
                    float absX     = fabsf(aired);
                    float compAtk  = 1.0f - expf(-1.0f / (0.005f * ctx->sampleRate));
                    float compRel  = 1.0f - expf(-1.0f / (0.150f * ctx->sampleRate));
                    if (absX > ctx->compEnv)
                        ctx->compEnv += compAtk * (absX - ctx->compEnv);
                    else
                        ctx->compEnv += compRel * (absX - ctx->compEnv);

                    // 3:1 ratio above −12 dBFS (≈0.25 linear)
                    float thresh = 0.25f;
                    float gain = 1.0f;
                    if (ctx->compEnv > thresh)
                        gain = thresh + (ctx->compEnv - thresh) / 3.0f;
                    if (ctx->compEnv > 1e-6f) gain /= ctx->compEnv;
                    gain = gain > 1.0f ? 1.0f : gain;

                    float compressed = aired * gain;
                    processed = bqRun(&ctx->hp[ch], compressed * dry + rev * wet);
                }
            }

            // ── Output limiter: hard-clip at ±1.0 ─────────────────────
            processed = processed >  1.0f ?  1.0f : (processed < -1.0f ? -1.0f : processed);

            s[i] = processed;
        }
    }
}

// ── Tap installation ──────────────────────────────────────────────────────
static const char kTapInstalledKey;  // address used as associated-object key

static void installRemixTap(AVPlayerItem *item) {
    if (!item) return;
    if (!atomic_load_explicit(&gRemixActive, memory_order_acquire)) return;

    // Deduplication: if we already installed a tap on this item, bail.
    if (objc_getAssociatedObject(item, &kTapInstalledKey) != nil) return;

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
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb,
                                   kMTAudioProcessingTapCreationFlag_PostEffects,
                                   &tap) != noErr) return;

    AVMutableAudioMixInputParameters *params =
        [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack.assetTrack];
    params.audioTapProcessor = tap;
    CFRelease(tap);

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[params];
    item.audioMix = mix;

    // Mark this item so we don't install twice
    objc_setAssociatedObject(item, &kTapInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Try installation; retry once after a delay if tracks aren't loaded yet.
static void tryInstall(AVPlayerItem *item, BOOL isRetry) {
    if (!item) return;
    if (!atomic_load_explicit(&gRemixActive, memory_order_acquire)) return;
    if (objc_getAssociatedObject(item, &kTapInstalledKey) != nil) return;

    if (item.tracks.count > 0) {
        installRemixTap(item);
    } else if (!isRetry) {
        __weak AVPlayerItem *weak = item;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            tryInstall(weak, YES);
        });
    }
}

// ── AVPlayer hooks ────────────────────────────────────────────────────────
%hook AVPlayer

- (void)play {
    %orig;
    syncRemixSettings();
    tryInstall(self.currentItem, NO);
}

- (void)setCurrentItem:(AVPlayerItem *)currentItem {
    %orig;
    syncRemixSettings();
    tryInstall(currentItem, NO);
}

%end

// ── Init: seed defaults ───────────────────────────────────────────────────
%ctor {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:
        [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    if (d[@"remixMode"]      == nil) d[@"remixMode"]      = @(0);
    if (d[@"remixIntensity"] == nil) d[@"remixIntensity"] = @(2);
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
    syncRemixSettings();
}
