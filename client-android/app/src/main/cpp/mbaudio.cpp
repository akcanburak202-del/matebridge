// T-100 / decision 0012: a thin AAudio output stream for AudioPlayout (AAudioSink.kt / AAudioNative.kt).
//
// The stream is owned by one thread (the Kotlin audio writer): open, start, write, timestamp, close are all called
// from it, so no locks are needed. The data path (write, timestamp, xruns) does not allocate, lock, log or call up
// into Java: PCM is copied with GetShortArrayRegion into a buffer allocated at open, then AAudioStream_write paces
// the writer at the device's clock (the bounded timeout keeps a stop responsive). Audio content is never logged.
#include <aaudio/AAudio.h>
#include <dlfcn.h>
#include <jni.h>
#include <time.h>

#include <cstdint>
#include <cstring>
#include <new>

namespace {

// Info layout filled by open(); must match AAudioNative.kt (I_* constants).
enum Info : int {
    I_ERROR = 0,  // aaudio_result_t of the failing call, 0 if none
    I_STAGE,      // 0 none, 1 builder, 2 open, 3 format, 4 alloc
    I_SHARING,    // granted sharing mode
    I_MMAP,       // 1 yes, 0 no, -1 unknown (symbol not exported)
    I_BURST,
    I_CAPACITY,
    I_BUF,        // buffer size after setting the requested start size
    I_RATE,
    I_CHANNELS,
    I_FORMAT,
    I_PERF,
    I_PRE,        // frames of silence written before start
    I_COUNT
};

enum Stage : int { S_NONE = 0, S_BUILDER, S_OPEN, S_FORMAT, S_ALLOC };

constexpr int32_t kRate = 48000;
constexpr int32_t kChannels = 2;

struct Out {
    AAudioStream* stream = nullptr;
    int16_t* buf = nullptr;
    int32_t bufFrames = 0;
    int32_t channels = 0;
};

Out* fromHandle(jlong h) { return reinterpret_cast<Out*>(static_cast<intptr_t>(h)); }

// AAudioStream_isMMapUsed is exported by libaaudio.so but not declared in the NDK headers. Resolved once.
using IsMMapUsedFn = bool (*)(AAudioStream*);
IsMMapUsedFn resolveIsMMapUsed() {
    void* lib = dlopen("libaaudio.so", RTLD_NOW | RTLD_NOLOAD);
    if (lib == nullptr) lib = dlopen("libaaudio.so", RTLD_NOW);
    if (lib == nullptr) return nullptr;
    // The library stays loaded (we link against it), so the handle is intentionally not closed.
    return reinterpret_cast<IsMMapUsedFn>(dlsym(lib, "AAudioStream_isMMapUsed"));
}

int queryMmap(AAudioStream* s) {
    static const IsMMapUsedFn fn = resolveIsMMapUsed();
    return fn == nullptr ? -1 : (fn(s) ? 1 : 0);
}

void fillInfo(JNIEnv* env, jintArray info, const int32_t* v) {
    if (info == nullptr || env->GetArrayLength(info) < I_COUNT) return;
    env->SetIntArrayRegion(info, 0, I_COUNT, reinterpret_cast<const jint*>(v));
}

void destroy(Out* o) {
    if (o == nullptr) return;
    if (o->stream != nullptr) {
        AAudioStream_requestStop(o->stream);
        AAudioStream_close(o->stream);
    }
    delete[] o->buf;
    delete o;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_dev_matebridge_client_audio_AAudioNative_open(JNIEnv* env, jobject, jint sharing, jint startBursts,
                                                    jintArray info) {
    int32_t v[I_COUNT] = {};
    v[I_MMAP] = -1;

    AAudioStreamBuilder* b = nullptr;
    aaudio_result_t r = AAudio_createStreamBuilder(&b);
    if (r != AAUDIO_OK) {
        v[I_ERROR] = r;
        v[I_STAGE] = S_BUILDER;
        fillInfo(env, info, v);
        return 0;
    }
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setSharingMode(b, static_cast<aaudio_sharing_mode_t>(sharing));
    AAudioStreamBuilder_setSampleRate(b, kRate);
    AAudioStreamBuilder_setChannelCount(b, kChannels);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setUsage(b, AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setContentType(b, AAUDIO_CONTENT_TYPE_MOVIE);

    AAudioStream* s = nullptr;
    r = AAudioStreamBuilder_openStream(b, &s);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) {
        v[I_ERROR] = r;
        v[I_STAGE] = S_OPEN;
        fillInfo(env, info, v);
        return 0;
    }

    v[I_SHARING] = AAudioStream_getSharingMode(s);
    v[I_PERF] = AAudioStream_getPerformanceMode(s);
    v[I_MMAP] = queryMmap(s);
    const int32_t burst = AAudioStream_getFramesPerBurst(s);
    const int32_t capacity = AAudioStream_getBufferCapacityInFrames(s);
    v[I_BURST] = burst;
    v[I_CAPACITY] = capacity;
    v[I_RATE] = AAudioStream_getSampleRate(s);
    v[I_CHANNELS] = AAudioStream_getChannelCount(s);
    v[I_FORMAT] = AAudioStream_getFormat(s);

    // AudioPlayout renders 48 kHz s16 stereo; anything else is refused (the caller falls back).
    if (v[I_FORMAT] != AAUDIO_FORMAT_PCM_I16 || v[I_RATE] != kRate || v[I_CHANNELS] != kChannels || burst <= 0 ||
        capacity < burst) {
        v[I_ERROR] = AAUDIO_ERROR_UNIMPLEMENTED;
        v[I_STAGE] = S_FORMAT;
        AAudioStream_close(s);
        fillInfo(env, info, v);
        return 0;
    }

    Out* o = new (std::nothrow) Out();
    int16_t* buf = new (std::nothrow) int16_t[static_cast<size_t>(capacity) * kChannels];
    if (o == nullptr || buf == nullptr) {
        delete o;
        delete[] buf;
        v[I_ERROR] = AAUDIO_ERROR_NO_MEMORY;
        v[I_STAGE] = S_ALLOC;
        AAudioStream_close(s);
        fillInfo(env, info, v);
        return 0;
    }
    std::memset(buf, 0, static_cast<size_t>(capacity) * kChannels * sizeof(int16_t));
    o->stream = s;
    o->buf = buf;
    o->bufFrames = capacity;
    o->channels = kChannels;

    const int32_t want = (startBursts < 1 ? 1 : startBursts) * burst;
    int32_t bufSize = AAudioStream_setBufferSizeInFrames(s, want < capacity ? want : capacity);
    if (bufSize < 0) bufSize = AAudioStream_getBufferSizeInFrames(s);
    v[I_BUF] = bufSize;

    // One burst of silence before start, so the device's first read is not counted as an xrun.
    const aaudio_result_t pre = AAudioStream_write(s, buf, burst, 0);
    v[I_PRE] = pre > 0 ? pre : 0;

    fillInfo(env, info, v);
    return static_cast<jlong>(reinterpret_cast<intptr_t>(o));
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_matebridge_client_audio_AAudioNative_start(JNIEnv*, jobject, jlong h) {
    Out* o = fromHandle(h);
    if (o == nullptr) return AAUDIO_ERROR_NULL;
    return AAudioStream_requestStart(o->stream);
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_matebridge_client_audio_AAudioNative_write(JNIEnv* env, jobject, jlong h, jshortArray data, jint frames,
                                                     jlong timeoutNs) {
    Out* o = fromHandle(h);
    if (o == nullptr || data == nullptr) return AAUDIO_ERROR_NULL;
    int32_t n = frames;
    if (n > o->bufFrames) n = o->bufFrames;
    const jsize avail = env->GetArrayLength(data) / o->channels;
    if (n > avail) n = avail;
    if (n <= 0) return 0;
    env->GetShortArrayRegion(data, 0, n * o->channels, reinterpret_cast<jshort*>(o->buf));
    return AAudioStream_write(o->stream, o->buf, n, timeoutNs);
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_matebridge_client_audio_AAudioNative_timestamp(JNIEnv* env, jobject, jlong h, jlongArray out) {
    Out* o = fromHandle(h);
    if (o == nullptr || out == nullptr || env->GetArrayLength(out) < 2) return AAUDIO_ERROR_NULL;
    int64_t v[2] = {0, 0};
    const aaudio_result_t r = AAudioStream_getTimestamp(o->stream, CLOCK_MONOTONIC, &v[0], &v[1]);
    if (r == AAUDIO_OK) env->SetLongArrayRegion(out, 0, 2, reinterpret_cast<const jlong*>(v));
    return r;
}

// T-101: AAudio's own counters and timestamp in one call (writer thread only; no alloc, lock, log or up-call).
// out: [0] getFramesWritten, [1] getFramesRead, [2] timestamp frame position, [3] timestamp ns, [4] now (CLOCK_MONOTONIC
// ns, read last). Returns the getTimestamp result; [2] and [3] are 0 unless it is AAUDIO_OK.
extern "C" JNIEXPORT jint JNICALL
Java_dev_matebridge_client_audio_AAudioNative_counters(JNIEnv* env, jobject, jlong h, jlongArray out) {
    Out* o = fromHandle(h);
    if (o == nullptr || out == nullptr || env->GetArrayLength(out) < 5) return AAUDIO_ERROR_NULL;
    int64_t v[5] = {0, 0, 0, 0, 0};
    const aaudio_result_t r = AAudioStream_getTimestamp(o->stream, CLOCK_MONOTONIC, &v[2], &v[3]);
    if (r != AAUDIO_OK) {
        v[2] = 0;
        v[3] = 0;
    }
    v[1] = AAudioStream_getFramesRead(o->stream);
    v[0] = AAudioStream_getFramesWritten(o->stream);
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    v[4] = static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
    env->SetLongArrayRegion(out, 0, 5, reinterpret_cast<const jlong*>(v));
    return r;
}

// T-110: output headroom = frames written - frames read (AAudio's own counters), read just before each write by the
// writer thread. No alloc, lock, log or up-call. getFramesRead is read last, so a read counter that moves in between
// only makes the value smaller (conservative). INT64_MIN for a null handle.
extern "C" JNIEXPORT jlong JNICALL
Java_dev_matebridge_client_audio_AAudioNative_headroom(JNIEnv*, jobject, jlong h) {
    Out* o = fromHandle(h);
    if (o == nullptr) return INT64_MIN;
    const int64_t written = AAudioStream_getFramesWritten(o->stream);
    const int64_t read = AAudioStream_getFramesRead(o->stream);
    return written - read;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_matebridge_client_audio_AAudioNative_xruns(JNIEnv*, jobject, jlong h) {
    Out* o = fromHandle(h);
    return o == nullptr ? AAUDIO_ERROR_NULL : AAudioStream_getXRunCount(o->stream);
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_matebridge_client_audio_AAudioNative_bufferSize(JNIEnv*, jobject, jlong h) {
    Out* o = fromHandle(h);
    return o == nullptr ? AAUDIO_ERROR_NULL : AAudioStream_getBufferSizeInFrames(o->stream);
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_matebridge_client_audio_AAudioNative_setBufferSize(JNIEnv*, jobject, jlong h, jint frames) {
    Out* o = fromHandle(h);
    return o == nullptr ? AAUDIO_ERROR_NULL : AAudioStream_setBufferSizeInFrames(o->stream, frames);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_matebridge_client_audio_AAudioNative_close(JNIEnv*, jobject, jlong h) {
    destroy(fromHandle(h));
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_matebridge_client_audio_AAudioNative_errorText(JNIEnv* env, jobject, jint code) {
    // For logs only (never on the data path).
    const char* t = AAudio_convertResultToText(static_cast<aaudio_result_t>(code));
    return env->NewStringUTF(t != nullptr ? t : "?");
}
