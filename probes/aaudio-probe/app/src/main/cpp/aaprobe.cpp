// T-099 AAudio output latency probe. One blocking JNI call per measurement; the Kotlin side does all math and
// logging (LatencyMath / NativeResult are JVM-tested). Plays a very quiet (-40 dBFS) 1 kHz tone.
#include <aaudio/AAudio.h>
#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <time.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {

constexpr const char* kTag = "MB/aaprobe";

// Result layout; must match NativeResult.kt (H_* constants).
enum Header : int {
    H_LEN = 0,           // header length in longs (== H_COUNT)
    H_ERROR,             // aaudio_result_t of the failing call, 0 if none
    H_STAGE,             // 0 none, 1 builder, 2 open, 3 start, 4 write, 5 format
    H_REQ_SHARING,
    H_SHARING,
    H_PERF,
    H_MMAP,              // 1 yes, 0 no, -1 unknown (symbol not found)
    H_BURST,
    H_CAPACITY,
    H_BUF_DEFAULT,       // bufferSize right after open
    H_BUF_START,         // bufferSize after we set 2 bursts
    H_BUF_FINAL,         // bufferSize at the end (grown by one burst per xrun increase)
    H_RATE,
    H_CHANNELS,
    H_FORMAT,
    H_XRUNS,
    H_FRAMES_WRITTEN,
    H_TS_FAIL,           // getTimestamp calls that did not return AAUDIO_OK
    H_START_NS,          // CLOCK_MONOTONIC right after requestStart
    H_SAMPLES,           // number of (written, position, timeNs, nowNs) quads that follow
    H_COUNT
};

enum Stage : int { S_NONE = 0, S_BUILDER, S_OPEN, S_START, S_WRITE, S_FORMAT };

constexpr int kMaxSamples = 16384;
constexpr int kStartBursts = 2;  // same as the product's AudioPlayout.START_BURSTS
constexpr double kToneHz = 1000.0;

std::atomic<bool> g_stop{false};

int64_t nowMono() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

// AAudioStream_isMMapUsed is exported by libaaudio.so but not declared in the NDK headers.
using IsMMapUsedFn = bool (*)(AAudioStream*);
int queryMmap(AAudioStream* s) {
    void* lib = dlopen("libaaudio.so", RTLD_NOW | RTLD_NOLOAD);
    if (lib == nullptr) lib = dlopen("libaaudio.so", RTLD_NOW);
    if (lib == nullptr) return -1;
    auto fn = reinterpret_cast<IsMMapUsedFn>(dlsym(lib, "AAudioStream_isMMapUsed"));
    int r = fn == nullptr ? -1 : (fn(s) ? 1 : 0);
    dlclose(lib);
    return r;
}

jlongArray toJava(JNIEnv* env, const std::vector<int64_t>& header, const std::vector<int64_t>& quads) {
    const jsize n = static_cast<jsize>(header.size() + quads.size());
    jlongArray out = env->NewLongArray(n);
    if (out == nullptr) return nullptr;
    env->SetLongArrayRegion(out, 0, static_cast<jsize>(header.size()), reinterpret_cast<const jlong*>(header.data()));
    if (!quads.empty()) {
        env->SetLongArrayRegion(out, static_cast<jsize>(header.size()), static_cast<jsize>(quads.size()),
                                reinterpret_cast<const jlong*>(quads.data()));
    }
    return out;
}

}  // namespace

extern "C" JNIEXPORT void JNICALL
Java_dev_matebridge_aaudioprobe_NativeProbe_resetStop(JNIEnv*, jobject) { g_stop.store(false); }

extern "C" JNIEXPORT void JNICALL
Java_dev_matebridge_aaudioprobe_NativeProbe_requestStop(JNIEnv*, jobject) { g_stop.store(true); }

extern "C" JNIEXPORT jlongArray JNICALL
Java_dev_matebridge_aaudioprobe_NativeProbe_runAaudio(JNIEnv* env, jobject, jint sharing, jint durationMs,
                                                       jfloat amplitude) {
    std::vector<int64_t> h(H_COUNT, 0);
    std::vector<int64_t> quads;
    h[H_LEN] = H_COUNT;
    h[H_REQ_SHARING] = sharing;
    h[H_MMAP] = -1;

    AAudioStreamBuilder* b = nullptr;
    aaudio_result_t r = AAudio_createStreamBuilder(&b);
    if (r != AAUDIO_OK) {
        h[H_ERROR] = r;
        h[H_STAGE] = S_BUILDER;
        return toJava(env, h, quads);
    }
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setSharingMode(b, static_cast<aaudio_sharing_mode_t>(sharing));
    AAudioStreamBuilder_setSampleRate(b, 48000);
    AAudioStreamBuilder_setChannelCount(b, 2);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setUsage(b, AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setContentType(b, AAUDIO_CONTENT_TYPE_MOVIE);

    AAudioStream* s = nullptr;
    r = AAudioStreamBuilder_openStream(b, &s);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) {
        h[H_ERROR] = r;
        h[H_STAGE] = S_OPEN;
        return toJava(env, h, quads);
    }

    h[H_SHARING] = AAudioStream_getSharingMode(s);
    h[H_PERF] = AAudioStream_getPerformanceMode(s);
    h[H_MMAP] = queryMmap(s);
    const int32_t burst = AAudioStream_getFramesPerBurst(s);
    const int32_t capacity = AAudioStream_getBufferCapacityInFrames(s);
    const int32_t rate = AAudioStream_getSampleRate(s);
    const int32_t channels = AAudioStream_getChannelCount(s);
    h[H_BURST] = burst;
    h[H_CAPACITY] = capacity;
    h[H_BUF_DEFAULT] = AAudioStream_getBufferSizeInFrames(s);
    h[H_RATE] = rate;
    h[H_CHANNELS] = channels;
    h[H_FORMAT] = AAudioStream_getFormat(s);

    if (h[H_FORMAT] != AAUDIO_FORMAT_PCM_I16 || burst <= 0 || channels <= 0 || rate <= 0) {
        h[H_ERROR] = AAUDIO_ERROR_UNIMPLEMENTED;
        h[H_STAGE] = S_FORMAT;
        AAudioStream_close(s);
        return toJava(env, h, quads);
    }

    int32_t bufSize = AAudioStream_setBufferSizeInFrames(s, kStartBursts * burst);
    if (bufSize < 0) bufSize = AAudioStream_getBufferSizeInFrames(s);
    h[H_BUF_START] = bufSize;

    std::vector<int16_t> buf(static_cast<size_t>(burst) * channels);
    const double step = 2.0 * M_PI * kToneHz / rate;
    const double amp = static_cast<double>(amplitude) * 32767.0;
    double phase = 0.0;
    auto fill = [&]() {
        for (int32_t f = 0; f < burst; ++f) {
            const auto v = static_cast<int16_t>(std::lround(amp * std::sin(phase)));
            phase += step;
            if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
            for (int32_t c = 0; c < channels; ++c) buf[static_cast<size_t>(f) * channels + c] = v;
        }
    };

    int64_t written = 0;
    // One burst before start so the first device read is not counted as an xrun (as in AudioPlayout).
    fill();
    const aaudio_result_t pre = AAudioStream_write(s, buf.data(), burst, 0);
    if (pre > 0) written += pre;

    r = AAudioStream_requestStart(s);
    if (r != AAUDIO_OK) {
        h[H_ERROR] = r;
        h[H_STAGE] = S_START;
        AAudioStream_close(s);
        return toJava(env, h, quads);
    }
    const int64_t startNs = nowMono();
    h[H_START_NS] = startNs;
    const int64_t endNs = startNs + static_cast<int64_t>(durationMs) * 1000000LL;

    quads.reserve(static_cast<size_t>(kMaxSamples) * 4);
    int32_t lastXruns = 0;
    int64_t tsFail = 0;
    while (!g_stop.load(std::memory_order_relaxed) && nowMono() < endNs) {
        fill();
        const aaudio_result_t w = AAudioStream_write(s, buf.data(), burst, 1000000000LL);
        if (w < 0) {
            h[H_ERROR] = w;
            h[H_STAGE] = S_WRITE;
            break;
        }
        written += w;

        const int32_t xr = AAudioStream_getXRunCount(s);
        if (xr > lastXruns) {
            lastXruns = xr;
            if (bufSize + burst <= capacity) {
                const int32_t got = AAudioStream_setBufferSizeInFrames(s, bufSize + burst);
                if (got > 0) bufSize = got;
            }
        }

        int64_t pos = 0;
        int64_t tNs = 0;
        if (AAudioStream_getTimestamp(s, CLOCK_MONOTONIC, &pos, &tNs) == AAUDIO_OK) {
            if (static_cast<int>(quads.size() / 4) < kMaxSamples) {
                quads.push_back(written);
                quads.push_back(pos);
                quads.push_back(tNs);
                quads.push_back(nowMono());
            }
        } else {
            ++tsFail;
        }
    }

    h[H_XRUNS] = AAudioStream_getXRunCount(s);
    h[H_BUF_FINAL] = AAudioStream_getBufferSizeInFrames(s);
    h[H_FRAMES_WRITTEN] = written;
    h[H_TS_FAIL] = tsFail;
    h[H_SAMPLES] = static_cast<int64_t>(quads.size() / 4);

    AAudioStream_requestStop(s);
    AAudioStream_close(s);
    if (h[H_ERROR] != 0) {
        __android_log_print(ANDROID_LOG_WARN, kTag, "aaudio stage=%lld err=%s", static_cast<long long>(h[H_STAGE]),
                            AAudio_convertResultToText(static_cast<aaudio_result_t>(h[H_ERROR])));
    }
    return toJava(env, h, quads);
}
