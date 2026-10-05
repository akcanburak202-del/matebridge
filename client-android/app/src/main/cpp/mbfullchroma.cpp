// T-259 / decision 0034: the GPU half of packed full colour (AVC444v2 two-stream 4:4:4).
//  - present*(): decoder images (AHardwareBuffer from an ImageReader) -> EGLImage -> external textures read RAW through
//                GL_EXT_YUV_target -> one merge pass (main + auxiliary, inverse AVC444v2 layout) or a main-only pass ->
//                the SurfaceView's EGL window surface. Swap interval 0 + eglPresentationTimeANDROID slot targets (no
//                standing queue, T-256). Per-frame EGL timestamps for the measurements.
//  - T-261:      with reuse enabled (presentSetReuseTolerance >= 0) the draw is two passes through a ping-pong RGBA8 state
//                texture (R,G,B = shown raw Y/Cb/Cr, A = reference luma): the state pass merges main + auxiliary, or for a
//                main-only frame keeps the last full colour of every 2x2 block that did not change (rule: video/ChromaReuse.kt),
//                the show pass converts the state to RGB for the window. gl_ms comes from the EGL rendering-complete stamp.
//  - raw*():     capability self-test: raw Y/Cb/Cr through GL_EXT_YUV_target vs a CPU copy of the same image.
// From the T-254/T-256 probe (probes/yuv444-probe/android). All GL calls of one context come from one thread (the Kotlin
// caller's); the present and the raw contexts are independent. The merge expressions mirror video/Avc444v2.kt.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#ifndef EGL_TIMESTAMPS_ANDROID
#define EGL_TIMESTAMPS_ANDROID 0x3430
#define EGL_RENDERING_COMPLETE_TIME_ANDROID 0x3435
#define EGL_COMPOSITION_LATCH_TIME_ANDROID 0x3436
#define EGL_DISPLAY_PRESENT_TIME_ANDROID 0x343A
#define EGL_TIMESTAMP_PENDING_ANDROID (-2)
#define EGL_TIMESTAMP_INVALID_ANDROID (-1)
#endif

namespace {

typedef EGLClientBuffer (*PFN_getNativeClientBuffer)(const struct AHardwareBuffer*);
typedef EGLBoolean (*PFN_getNextFrameId)(EGLDisplay, EGLSurface, uint64_t*);
typedef EGLBoolean (*PFN_getFrameTimestamps)(EGLDisplay, EGLSurface, uint64_t, EGLint, const EGLint*, int64_t*);
typedef EGLBoolean (*PFN_tsSupported)(EGLDisplay, EGLSurface, EGLint);
typedef EGLBoolean (*PFN_presentationTime)(EGLDisplay, EGLSurface, EGLnsecsANDROID);

PFN_getNativeClientBuffer pGetNativeClientBuffer;
PFNEGLCREATEIMAGEKHRPROC pCreateImage;
PFNEGLDESTROYIMAGEKHRPROC pDestroyImage;
PFNGLEGLIMAGETARGETTEXTURE2DOESPROC pImageTarget;
PFN_getNextFrameId pNextFrameId;
PFN_getFrameTimestamps pFrameTimestamps;
PFN_tsSupported pTsSupported;
PFN_presentationTime pPresentationTime;

void loadProcs() {
    pGetNativeClientBuffer = (PFN_getNativeClientBuffer)eglGetProcAddress("eglGetNativeClientBufferANDROID");
    pCreateImage = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    pDestroyImage = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    pImageTarget = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    pNextFrameId = (PFN_getNextFrameId)eglGetProcAddress("eglGetNextFrameIdANDROID");
    pFrameTimestamps = (PFN_getFrameTimestamps)eglGetProcAddress("eglGetFrameTimestampsANDROID");
    pTsSupported = (PFN_tsSupported)eglGetProcAddress("eglGetFrameTimestampSupportedANDROID");
    pPresentationTime = (PFN_presentationTime)eglGetProcAddress("eglPresentationTimeANDROID");
}

std::string fmt(const char* f, ...) __attribute__((format(printf, 1, 2)));
std::string fmt(const char* f, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, f);
    vsnprintf(buf, sizeof buf, f, ap);
    va_end(ap);
    return buf;
}

bool hasExt(const char* list, const char* name) {
    if (!list) return false;
    size_t n = strlen(name);
    for (const char* p = list; (p = strstr(p, name)) != nullptr; p += n) {
        bool startOk = (p == list || p[-1] == ' ');
        bool endOk = (p[n] == ' ' || p[n] == 0);
        if (startOk && endOk) return true;
    }
    return false;
}

struct Imported {
    EGLImageKHR image;
    GLuint tex;
    uint64_t lastUse;
};

constexpr size_t kMaxCachedImages = 16;
// Draws in flight (fences not yet signalled) beyond which a new draw is refused: the GPU is not keeping up or a fence is stuck.
constexpr size_t kMaxFences = 8;

struct Ctx {
    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLContext ctx = EGL_NO_CONTEXT;
    EGLSurface surf = EGL_NO_SURFACE;
    ANativeWindow* window = nullptr;
    std::unordered_map<AHardwareBuffer*, Imported> cache;
    uint64_t useClock = 0;
    GLuint progMerge = 0, progMain = 0, progDump = 0;
    // T-261 temporal reuse: state pass (merge / main-only with reuse), show pass, sampled reuse measurement.
    GLuint progStateMerge = 0, progStateMain = 0, progShow = 0, progSample = 0;
    GLuint stateTex[2] = {0, 0}, stateFbo[2] = {0, 0};
    GLuint sampleTex = 0, sampleFbo = 0;
    int stateCur = 0;           // index of the state texture holding the last shown frame
    bool stateValid = false;    // a frame has been drawn through the state passes (something to reuse)
    bool reuseOk = false;       // programs and render targets exist
    int reuseTol = 2;           // 8-bit steps; < 0 = reuse off (the single-pass draw is used)
    bool samplePending = false;
    int64_t sampleDrawNo = 0;   // fencesPushed value whose completion makes the sample readable
    int64_t sampleTick = 0;
    int64_t reuseSame = 0, reuseTotal = 0;
    int64_t fencesPushed = 0;
    GLuint vao = 0;
    GLuint fbo = 0, fboTex = 0;
    int fboW = 0, fboH = 0;
    // present state
    int width = 0, height = 0;
    float conv[7] = {0, 1, 1, 1.5748f, -0.1873f, -0.4681f, 1.8556f};
    struct Pending {
        uint64_t id;
        int64_t tag;
        int64_t submitNs;  // CLOCK_MONOTONIC just before the swap: gl_ms = rendering complete - submitNs
    };
    std::deque<Pending> pendingTs;
    std::deque<GLsync> fences;  // one per submitted draw, in order; nullptr = created after a glFinish (already complete)
    int64_t fencesDone = 0;     // draws whose GPU work is known complete
    std::vector<int64_t> tsOut;  // quintuples: tag, latch, present, rendering complete, submit
    bool timestamps = false;
    bool tsRender = false;   // EGL_RENDERING_COMPLETE_TIME_ANDROID supported (else reported as 0)
    bool tsPresent = false;  // EGL_DISPLAY_PRESENT_TIME_ANDROID supported (else the latch time stands in)
    std::string lastError;
};

std::unique_ptr<Ctx> gRaw;
std::unique_ptr<Ctx> gPres;

const char* kVs = R"(#version 300 es
out vec2 vUv;
uniform float uFlip;
void main() {
  vec2 p = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
  vUv = vec2(p.x, mix(p.y, 1.0 - p.y, uFlip));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

// Raw bit-exact dump: R = Y, G = Cb, B = Cr (no conversion). Capability self-test only.
const char* kFsDump = R"(#version 300 es
#extension GL_EXT_YUV_target : require
precision highp float;
precision highp int;
uniform __samplerExternal2DY2YEXT uMain;
in vec2 vUv;
out vec4 o;
void main() { o = vec4(texture(uMain, vUv).rgb, 1.0); }
)";

// Main picture only (auxiliary missing or late): the driver upsamples the main view's 4:2:0 chroma.
const char* kFsMain = R"(#version 300 es
#extension GL_EXT_YUV_target : require
precision highp float;
precision highp int;
uniform __samplerExternal2DY2YEXT uMain;
uniform vec3 uConv0;  // yOffset, yScale, cScale
uniform vec4 uConv1;  // crR, cbG, crG, cbB
in vec2 vUv;
out vec4 o;
void main() {
  vec3 m = texture(uMain, vUv).rgb;
  float y = (m.r - uConv0.x) * uConv0.y;
  float cb = (m.g - 0.50196078) * uConv0.z;
  float cr = (m.b - 0.50196078) * uConv0.z;
  o = vec4(y + uConv1.x * cr, y + uConv1.y * cb + uConv1.z * cr, y + uConv1.w * cb, 1.0);
}
)";

// The inverse AVC444v2 layout (video/Avc444v2.kt `home`, same order of cases). Every texture fetch is nearest, at a
// sample centre: luma at (p + 0.5) / size, a chroma sample of the 4:2:0 planes at luma coordinates (2c + 1) / size.
const char* kFsMerge = R"(#version 300 es
#extension GL_EXT_YUV_target : require
precision highp float;
precision highp int;
uniform __samplerExternal2DY2YEXT uMain;
uniform __samplerExternal2DY2YEXT uAux;
uniform ivec2 uSize;
uniform vec3 uConv0;  // yOffset, yScale, cScale
uniform vec4 uConv1;  // crR, cbG, crG, cbB
in vec2 vUv;
out vec4 o;
void main() {
  vec2 inv = 1.0 / vec2(uSize);
  ivec2 p = clamp(ivec2(floor(vUv * vec2(uSize))), ivec2(0), uSize - ivec2(1));
  float y = texture(uMain, (vec2(p) + 0.5) * inv).r;
  float cb;
  float cr;
  if ((p.x & 1) == 1) {
    // odd column: auxiliary luma, left half Cb, right half Cr
    int ax = (p.x - 1) >> 1;
    cb = texture(uAux, (vec2(float(ax), float(p.y)) + 0.5) * inv).r;
    cr = texture(uAux, (vec2(float(ax + (uSize.x >> 1)), float(p.y)) + 0.5) * inv).r;
  } else if ((p.y & 1) == 0) {
    // (even, even): the main picture's own chroma
    vec3 m = texture(uMain, (vec2(p) + 1.0) * inv).rgb;
    cb = m.g;
    cr = m.b;
  } else {
    // even column, odd row: auxiliary chroma planes (columns = 0 mod 4 in aux Cb, = 2 mod 4 in aux Cr)
    int j = (p.y - 1) >> 1;
    bool second = (p.x & 3) == 2;
    int x = second ? ((p.x - 2) >> 2) : (p.x >> 2);
    int q = uSize.x >> 2;
    vec3 a1 = texture(uAux, vec2(float(2 * x + 1), float(2 * j + 1)) * inv).rgb;
    vec3 a2 = texture(uAux, vec2(float(2 * (x + q) + 1), float(2 * j + 1)) * inv).rgb;
    cb = second ? a1.b : a1.g;
    cr = second ? a2.b : a2.g;
  }
  float yy = (y - uConv0.x) * uConv0.y;
  float u = (cb - 0.50196078) * uConv0.z;
  float v = (cr - 0.50196078) * uConv0.z;
  o = vec4(yy + uConv1.x * v, yy + uConv1.y * u + uConv1.z * v, yy + uConv1.w * u, 1.0);
}
)";

// ---- T-261: state passes (temporal chroma reuse). The state texture is RGBA8 in BUFFER coordinates (texel row r = buffer
// row r, rendered with uFlip = 0): R,G,B = raw Y/Cb/Cr as shown, A = reference luma (reset together with the block's chroma).

const char* kStateHead = R"(#version 300 es
#extension GL_EXT_YUV_target : require
precision highp float;
precision highp int;
precision highp sampler2D;
uniform __samplerExternal2DY2YEXT uMain;
uniform ivec2 uSize;
in vec2 vUv;
out vec4 o;
)";

// Same cases as kFsMerge / video/Avc444v2.kt `home`; returns raw (y, cb, cr).
const char* kStateMergeFn = R"(
uniform __samplerExternal2DY2YEXT uAux;
vec3 mergeYcc(ivec2 p) {
  vec2 inv = 1.0 / vec2(uSize);
  float y = texture(uMain, (vec2(p) + 0.5) * inv).r;
  float cb;
  float cr;
  if ((p.x & 1) == 1) {
    int ax = (p.x - 1) >> 1;
    cb = texture(uAux, (vec2(float(ax), float(p.y)) + 0.5) * inv).r;
    cr = texture(uAux, (vec2(float(ax + (uSize.x >> 1)), float(p.y)) + 0.5) * inv).r;
  } else if ((p.y & 1) == 0) {
    vec3 m = texture(uMain, (vec2(p) + 1.0) * inv).rgb;
    cb = m.g;
    cr = m.b;
  } else {
    int j = (p.y - 1) >> 1;
    bool second = (p.x & 3) == 2;
    int x = second ? ((p.x - 2) >> 2) : (p.x >> 2);
    int q = uSize.x >> 2;
    vec3 a1 = texture(uAux, vec2(float(2 * x + 1), float(2 * j + 1)) * inv).rgb;
    vec3 a2 = texture(uAux, vec2(float(2 * (x + q) + 1), float(2 * j + 1)) * inv).rgb;
    cb = second ? a1.b : a1.g;
    cr = second ? a2.b : a2.g;
  }
  return vec3(y, cb, cr);
}
void main() {
  ivec2 p = clamp(ivec2(floor(vUv * vec2(uSize))), ivec2(0), uSize - ivec2(1));
  vec3 c = mergeYcc(p);
  o = vec4(c, c.x);
}
)";

// The block rule of video/ChromaReuse.kt (blockUnchanged): 4 luma samples vs the reference luma (state.a) and the main
// chroma sample vs the state's chroma at the block's (even, even) pixel. uTol = (tolerance + 0.5) / 255.
const char* kStateReuseFn = R"(
uniform sampler2D uState;
uniform float uTol;
bool blockSame(ivec2 b, vec2 inv) {
  float d = 0.0;
  for (int i = 0; i < 4; i++) {
    ivec2 q = b + ivec2(i & 1, i >> 1);
    float y = texture(uMain, (vec2(q) + 0.5) * inv).r;
    d = max(d, abs(y - texelFetch(uState, q, 0).a));
  }
  vec3 m = texture(uMain, (vec2(b) + 1.0) * inv).rgb;
  vec4 s = texelFetch(uState, b, 0);
  d = max(d, max(abs(m.g - s.g), abs(m.b - s.b)));
  return d <= uTol;
}
)";

const char* kStateMainMain = R"(
uniform int uUseRef;
void main() {
  vec2 inv = 1.0 / vec2(uSize);
  ivec2 p = clamp(ivec2(floor(vUv * vec2(uSize))), ivec2(0), uSize - ivec2(1));
  ivec2 b = p & ivec2(-2);
  float y = texture(uMain, (vec2(p) + 0.5) * inv).r;
  if (uUseRef == 1 && blockSame(b, inv)) {
    vec4 s = texelFetch(uState, p, 0);
    o = vec4(y, s.g, s.b, s.a);
  } else {
    vec3 m = texture(uMain, (vec2(b) + 1.0) * inv).rgb;
    o = vec4(y, m.g, m.b, y);
  }
}
)";

// 64 x 40 sample grid: one block per texel, 1.0 where the block would reuse the state (the reuse_pct measurement).
const char* kStateSampleMain = R"(
void main() {
  vec2 inv = 1.0 / vec2(uSize);
  ivec2 nb = uSize / 2;
  ivec2 s = ivec2(gl_FragCoord.xy);
  ivec2 bq = ((s * 2 + 1) * nb) / (2 * ivec2(64, 40));
  ivec2 b = bq * 2;
  o = blockSame(b, inv) ? vec4(1.0) : vec4(0.0);
}
)";

// Shows the state: raw YCbCr -> RGB (same conversion as kFsMain).
const char* kFsShow = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uState;
uniform vec3 uConv0;  // yOffset, yScale, cScale
uniform vec4 uConv1;  // crR, cbG, crG, cbB
in vec2 vUv;
out vec4 o;
void main() {
  vec3 m = texture(uState, vUv).rgb;
  float y = (m.r - uConv0.x) * uConv0.y;
  float cb = (m.g - 0.50196078) * uConv0.z;
  float cr = (m.b - 0.50196078) * uConv0.z;
  o = vec4(y + uConv1.x * cr, y + uConv1.y * cb + uConv1.z * cr, y + uConv1.w * cb, 1.0);
}
)";

GLuint compile(GLenum type, const char* src, std::string& err) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[600] = {0};
        glGetShaderInfoLog(s, sizeof log - 1, nullptr, log);
        err = std::string("shader:") + log;
        for (auto& ch : err) {
            if (ch == '\n') ch = ' ';
        }
        glDeleteShader(s);
        return 0;
    }
    return s;
}

GLuint program(const char* fs, std::string& err) {
    GLuint v = compile(GL_VERTEX_SHADER, kVs, err);
    if (!v) return 0;
    GLuint f = compile(GL_FRAGMENT_SHADER, fs, err);
    if (!f) {
        glDeleteShader(v);
        return 0;
    }
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    glDeleteShader(v);
    glDeleteShader(f);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[600] = {0};
        glGetProgramInfoLog(p, sizeof log - 1, nullptr, log);
        err = std::string("link:") + log;
        for (auto& ch : err) {
            if (ch == '\n') ch = ' ';
        }
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

bool initEgl(Ctx& c, ANativeWindow* window, std::string& err) {
    c.dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint maj = 0, min = 0;
    if (!eglInitialize(c.dpy, &maj, &min)) {
        err = "eglInitialize";
        return false;
    }
    const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                            EGL_SURFACE_TYPE, window ? EGL_WINDOW_BIT : EGL_PBUFFER_BIT,
                            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig cfg = nullptr;
    EGLint n = 0;
    if (!eglChooseConfig(c.dpy, attrs, &cfg, 1, &n) || n < 1) {
        err = "eglChooseConfig";
        return false;
    }
    const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    c.ctx = eglCreateContext(c.dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
    if (c.ctx == EGL_NO_CONTEXT) {
        err = fmt("eglCreateContext:0x%x", eglGetError());
        return false;
    }
    if (window) {
        c.surf = eglCreateWindowSurface(c.dpy, cfg, window, nullptr);
    } else {
        const EGLint pb[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        c.surf = eglCreatePbufferSurface(c.dpy, cfg, pb);
    }
    if (c.surf == EGL_NO_SURFACE) {
        err = fmt("eglCreateSurface:0x%x", eglGetError());
        return false;
    }
    if (!eglMakeCurrent(c.dpy, c.surf, c.surf, c.ctx)) {
        err = fmt("eglMakeCurrent:0x%x", eglGetError());
        return false;
    }
    loadProcs();
    if (!pGetNativeClientBuffer || !pCreateImage || !pDestroyImage || !pImageTarget) {
        err = "missing EGL_ANDROID_get_native_client_buffer / EGL_KHR_image_base entry points";
        return false;
    }
    glGenVertexArrays(1, &c.vao);
    glBindVertexArray(c.vao);
    return true;
}

void dropImported(Ctx& c, const Imported& im) {
    glDeleteTextures(1, &im.tex);
    pDestroyImage(c.dpy, im.image);
}

GLuint importBuffer(Ctx& c, AHardwareBuffer* ahb) {
    c.useClock++;
    auto it = c.cache.find(ahb);
    if (it != c.cache.end()) {
        it->second.lastUse = c.useClock;
        return it->second.tex;
    }
    // Bounded: an ImageReader recycles a handful of buffers; evict the least recently used import beyond that.
    while (c.cache.size() >= kMaxCachedImages) {
        auto oldest = c.cache.begin();
        for (auto i = c.cache.begin(); i != c.cache.end(); ++i) {
            if (i->second.lastUse < oldest->second.lastUse) oldest = i;
        }
        dropImported(c, oldest->second);
        c.cache.erase(oldest);
    }
    EGLClientBuffer cb = pGetNativeClientBuffer(ahb);
    const EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    EGLImageKHR img = pCreateImage(c.dpy, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, cb, attrs);
    if (img == EGL_NO_IMAGE_KHR) {
        c.lastError = fmt("eglCreateImageKHR:0x%x", eglGetError());
        return 0;
    }
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    pImageTarget(GL_TEXTURE_EXTERNAL_OES, (GLeglImageOES)img);
    GLenum e = glGetError();
    if (e != GL_NO_ERROR) {
        c.lastError = fmt("glEGLImageTargetTexture2DOES:0x%x", e);
        glDeleteTextures(1, &tex);
        pDestroyImage(c.dpy, img);
        return 0;
    }
    c.cache[ahb] = {img, tex, c.useClock};
    return tex;
}

bool makeTarget(GLuint& tex, GLuint& fbo, int w, int h, std::string& err) {
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        err = "reuse fbo incomplete";
        return false;
    }
    glClearColor(0.f, 0.f, 0.f, 0.f);
    glClear(GL_COLOR_BUFFER_BIT);
    return true;
}

// Programs and render targets of the T-261 state passes. False (with [err]) = reuse is unavailable; the caller keeps the
// single-pass draw. Everything created here is released by destroy() / dropReuse().
bool initReuse(Ctx& c, std::string& err) {
    const std::string head = kStateHead;
    const std::string mergeSrc = head + kStateMergeFn;
    const std::string mainSrc = head + kStateReuseFn + kStateMainMain;
    const std::string sampleSrc = head + kStateReuseFn + kStateSampleMain;
    c.progStateMerge = program(mergeSrc.c_str(), err);
    if (!c.progStateMerge) { err = "state_merge:" + err; return false; }
    c.progStateMain = program(mainSrc.c_str(), err);
    if (!c.progStateMain) { err = "state_main:" + err; return false; }
    c.progSample = program(sampleSrc.c_str(), err);
    if (!c.progSample) { err = "state_sample:" + err; return false; }
    c.progShow = program(kFsShow, err);
    if (!c.progShow) { err = "show:" + err; return false; }
    if (!makeTarget(c.stateTex[0], c.stateFbo[0], c.width, c.height, err)) return false;
    if (!makeTarget(c.stateTex[1], c.stateFbo[1], c.width, c.height, err)) return false;
    if (!makeTarget(c.sampleTex, c.sampleFbo, 64, 40, err)) return false;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    const GLenum e = glGetError();
    if (e != GL_NO_ERROR) {
        err = fmt("reuse glerr:0x%x", e);
        return false;
    }
    c.stateCur = 0;
    c.stateValid = false;
    return true;
}

// Releases the T-261 objects (also after a partial initReuse).
void dropReuse(Ctx& c) {
    if (c.progStateMerge) glDeleteProgram(c.progStateMerge);
    if (c.progStateMain) glDeleteProgram(c.progStateMain);
    if (c.progShow) glDeleteProgram(c.progShow);
    if (c.progSample) glDeleteProgram(c.progSample);
    c.progStateMerge = c.progStateMain = c.progShow = c.progSample = 0;
    for (int i = 0; i < 2; i++) {
        if (c.stateFbo[i]) glDeleteFramebuffers(1, &c.stateFbo[i]);
        if (c.stateTex[i]) glDeleteTextures(1, &c.stateTex[i]);
        c.stateFbo[i] = c.stateTex[i] = 0;
    }
    if (c.sampleFbo) glDeleteFramebuffers(1, &c.sampleFbo);
    if (c.sampleTex) glDeleteTextures(1, &c.sampleTex);
    c.sampleFbo = c.sampleTex = 0;
    c.reuseOk = false;
    c.stateValid = false;
    c.samplePending = false;
}

void destroy(std::unique_ptr<Ctx>& p) {
    if (!p) return;
    Ctx& c = *p;
    if (c.dpy != EGL_NO_DISPLAY && c.ctx != EGL_NO_CONTEXT && c.surf != EGL_NO_SURFACE) {
        eglMakeCurrent(c.dpy, c.surf, c.surf, c.ctx);
        for (auto& kv : c.cache) dropImported(c, kv.second);
        c.cache.clear();
        if (c.progMerge) glDeleteProgram(c.progMerge);
        if (c.progMain) glDeleteProgram(c.progMain);
        if (c.progDump) glDeleteProgram(c.progDump);
        dropReuse(c);
        for (GLsync f : c.fences) {
            if (f) glDeleteSync(f);
        }
        c.fences.clear();
        if (c.fbo) glDeleteFramebuffers(1, &c.fbo);
        if (c.fboTex) glDeleteTextures(1, &c.fboTex);
        if (c.vao) glDeleteVertexArrays(1, &c.vao);
    }
    if (c.dpy != EGL_NO_DISPLAY) {
        eglMakeCurrent(c.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (c.surf != EGL_NO_SURFACE) eglDestroySurface(c.dpy, c.surf);
        if (c.ctx != EGL_NO_CONTEXT) eglDestroyContext(c.dpy, c.ctx);
        eglTerminate(c.dpy);
    }
    if (c.window) ANativeWindow_release(c.window);
    p.reset();
}

jstring str(JNIEnv* env, const std::string& s) { return env->NewStringUTF(s.c_str()); }

struct Diff {
    long long mis = 0, total = 0;
    int maxd = 0;
    void add(int a, int b) {
        total++;
        if (a != b) {
            mis++;
            maxd = std::max(maxd, std::abs(a - b));
        }
    }
};

// Pops the fences that signalled (in order). A failed wait (GL_WAIT_FAILED) is handled by finishing the queue: glFinish
// completes every earlier draw, so all queued fences count as done.
void pollFences(Ctx& c) {
    while (!c.fences.empty()) {
        GLsync f = c.fences.front();
        if (f) {
            GLenum r = glClientWaitSync(f, 0, 0);
            if (r == GL_WAIT_FAILED) {
                glFinish();
                for (GLsync g : c.fences) {
                    if (g) glDeleteSync(g);
                }
                c.fencesDone += (int64_t)c.fences.size();
                c.fences.clear();
                return;
            }
            if (r != GL_ALREADY_SIGNALED && r != GL_CONDITION_SATISFIED) return;
            glDeleteSync(f);
        }
        c.fences.pop_front();
        c.fencesDone++;
    }
}

// Reads the sampled reuse grid of an earlier draw once that draw's fence signalled (the GPU is done with it, so the tiny
// readback does not stall). GL thread only.
void pollSample(Ctx& c) {
    if (!c.samplePending || c.fencesDone < c.sampleDrawNo) return;
    uint8_t px[64 * 40 * 4];
    glBindFramebuffer(GL_FRAMEBUFFER, c.sampleFbo);
    glReadPixels(0, 0, 64, 40, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (glGetError() == GL_NO_ERROR) {
        for (int i = 0; i < 64 * 40; i++) {
            if (px[i * 4] > 127) c.reuseSame++;
            c.reuseTotal++;
        }
    }
    c.samplePending = false;
}

int64_t monotonicNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

void pollTimestamps(Ctx& c) {
    // Only the supported timestamps are queried (an unsupported name fails the whole query): latch is required
    // (checked at init), present falls back to latch, rendering-complete to 0.
    EGLint names[3];
    int n = 0, iRender = -1, iLatch = -1, iPresent = -1;
    if (c.tsRender) { iRender = n; names[n++] = EGL_RENDERING_COMPLETE_TIME_ANDROID; }
    iLatch = n; names[n++] = EGL_COMPOSITION_LATCH_TIME_ANDROID;
    if (c.tsPresent) { iPresent = n; names[n++] = EGL_DISPLAY_PRESENT_TIME_ANDROID; }
    while (!c.pendingTs.empty()) {
        auto p = c.pendingTs.front();
        int64_t v[3] = {0, 0, 0};
        if (!pFrameTimestamps(c.dpy, c.surf, p.id, n, names, v)) {
            c.pendingTs.pop_front();  // history no longer holds this frame
            continue;
        }
        if (v[iLatch] == EGL_TIMESTAMP_PENDING_ANDROID || (iPresent >= 0 && v[iPresent] == EGL_TIMESTAMP_PENDING_ANDROID)) {
            if (c.pendingTs.size() > 12) {
                c.pendingTs.pop_front();  // too far behind: give up on the oldest
                continue;
            }
            break;
        }
        int64_t latch = v[iLatch];
        int64_t present = (iPresent >= 0 && v[iPresent] > 0) ? v[iPresent] : latch;
        c.tsOut.push_back(p.tag);
        c.tsOut.push_back(latch);
        c.tsOut.push_back(present);
        c.tsOut.push_back(iRender >= 0 ? v[iRender] : 0);
        c.tsOut.push_back(p.submitNs);
        c.pendingTs.pop_front();
    }
}

// The single-pass draw (T-259): main (+ auxiliary: merge) straight into the window surface.
void drawDirect(Ctx& c, GLuint mt, GLuint at) {
    const GLuint p = at ? c.progMerge : c.progMain;
    glUseProgram(p);
    glUniform1f(glGetUniformLocation(p, "uFlip"), 1.0f);
    glUniform1i(glGetUniformLocation(p, "uMain"), 0);
    glUniform3f(glGetUniformLocation(p, "uConv0"), c.conv[0], c.conv[1], c.conv[2]);
    glUniform4f(glGetUniformLocation(p, "uConv1"), c.conv[3], c.conv[4], c.conv[5], c.conv[6]);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, mt);
    if (at) {
        glUniform1i(glGetUniformLocation(p, "uAux"), 1);
        glUniform2i(glGetUniformLocation(p, "uSize"), c.width, c.height);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_EXTERNAL_OES, at);
        glActiveTexture(GL_TEXTURE0);
    }
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

// T-261: state pass (into the other state texture) + show pass (into the window surface).
void drawReuse(Ctx& c, GLuint mt, GLuint at) {
    const int cur = c.stateCur;
    const int nxt = 1 - cur;
    const bool useRef = !at && c.stateValid;
    const float tol = ((float)c.reuseTol + 0.5f) / 255.0f;

    glBindFramebuffer(GL_FRAMEBUFFER, c.stateFbo[nxt]);
    glViewport(0, 0, c.width, c.height);
    const GLuint p = at ? c.progStateMerge : c.progStateMain;
    glUseProgram(p);
    glUniform1f(glGetUniformLocation(p, "uFlip"), 0.0f);
    glUniform1i(glGetUniformLocation(p, "uMain"), 0);
    glUniform2i(glGetUniformLocation(p, "uSize"), c.width, c.height);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, mt);
    if (at) {
        glUniform1i(glGetUniformLocation(p, "uAux"), 1);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_EXTERNAL_OES, at);
    } else {
        glUniform1i(glGetUniformLocation(p, "uState"), 2);
        glUniform1f(glGetUniformLocation(p, "uTol"), tol);
        glUniform1i(glGetUniformLocation(p, "uUseRef"), useRef ? 1 : 0);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, c.stateTex[cur]);
    }
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    // Sparse measurement of the reuse fraction: every 4th main-only draw one block per texel of a 64 x 40 grid (reads the
    // state this draw read, i.e. before the swap of the state textures). Read back later, see pollSample.
    if (useRef && !c.samplePending && (c.sampleTick++ % 4) == 0) {
        glBindFramebuffer(GL_FRAMEBUFFER, c.sampleFbo);
        glViewport(0, 0, 64, 40);
        glUseProgram(c.progSample);
        glUniform1f(glGetUniformLocation(c.progSample, "uFlip"), 0.0f);
        glUniform1i(glGetUniformLocation(c.progSample, "uMain"), 0);
        glUniform1i(glGetUniformLocation(c.progSample, "uState"), 2);
        glUniform2i(glGetUniformLocation(c.progSample, "uSize"), c.width, c.height);
        glUniform1f(glGetUniformLocation(c.progSample, "uTol"), tol);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_EXTERNAL_OES, mt);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, c.stateTex[cur]);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        c.samplePending = true;
        c.sampleDrawNo = c.fencesPushed + 1;  // the fence of THIS draw is pushed right after it (presentDraw)
    }
    c.stateCur = nxt;
    c.stateValid = true;

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, c.width, c.height);
    glUseProgram(c.progShow);
    glUniform1f(glGetUniformLocation(c.progShow, "uFlip"), 1.0f);
    glUniform1i(glGetUniformLocation(c.progShow, "uState"), 2);
    glUniform3f(glGetUniformLocation(c.progShow, "uConv0"), c.conv[0], c.conv[1], c.conv[2]);
    glUniform4f(glGetUniformLocation(c.progShow, "uConv1"), c.conv[3], c.conv[4], c.conv[5], c.conv[6]);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, c.stateTex[nxt]);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glActiveTexture(GL_TEXTURE0);
}

}  // namespace

extern "C" {

// ---- capability self-test: raw sampling comparison ----

JNIEXPORT jstring JNICALL Java_dev_matebridge_client_video_FullChromaNative_rawInit(JNIEnv* env, jclass) {
    destroy(gRaw);
    gRaw.reset(new Ctx());
    std::string err;
    if (!initEgl(*gRaw, nullptr, err)) {
        std::string e = err;
        destroy(gRaw);
        return str(env, e);
    }
    const char* glExt = (const char*)glGetString(GL_EXTENSIONS);
    if (!hasExt(glExt, "GL_EXT_YUV_target")) {
        destroy(gRaw);
        return str(env, "GL_EXT_YUV_target not exposed");
    }
    GLuint p = program(kFsDump, err);
    if (!p) {
        std::string e = err;
        destroy(gRaw);
        return str(env, e);
    }
    gRaw->progDump = p;
    return str(env, "");
}

JNIEXPORT void JNICALL Java_dev_matebridge_client_video_FullChromaNative_rawShutdown(JNIEnv*, jclass) { destroy(gRaw); }

// Renders the raw Y/Cb/Cr of [hwb] at full resolution (compares Y) and at half resolution on chroma texel centres
// (compares Cb, Cr exactly). Planes are tightly packed. One result line; `exact=1` when every sample matched.
JNIEXPORT jstring JNICALL Java_dev_matebridge_client_video_FullChromaNative_rawCompare(
    JNIEnv* env, jclass, jobject hwb, jint w, jint h, jbyteArray yArr, jbyteArray uArr, jbyteArray vArr) {
    if (!gRaw) return str(env, "ok=0 err=not_initialised");
    Ctx& c = *gRaw;
    AHardwareBuffer* ahb = AHardwareBuffer_fromHardwareBuffer(env, hwb);
    if (!ahb) return str(env, "ok=0 err=no_ahb");
    AHardwareBuffer_Desc desc;
    AHardwareBuffer_describe(ahb, &desc);
    GLuint tex = importBuffer(c, ahb);
    if (!tex) return str(env, "ok=0 err=" + c.lastError);
    const int cw = w / 2, ch = h / 2;
    std::vector<uint8_t> Y(w * (size_t)h), U(cw * (size_t)ch), V(cw * (size_t)ch);
    env->GetByteArrayRegion(yArr, 0, (jsize)Y.size(), (jbyte*)Y.data());
    env->GetByteArrayRegion(uArr, 0, (jsize)U.size(), (jbyte*)U.data());
    env->GetByteArrayRegion(vArr, 0, (jsize)V.size(), (jbyte*)V.data());

    if (c.fboW != w || c.fboH != h) {
        if (c.fbo) glDeleteFramebuffers(1, &c.fbo);
        if (c.fboTex) glDeleteTextures(1, &c.fboTex);
        glGenTextures(1, &c.fboTex);
        glBindTexture(GL_TEXTURE_2D, c.fboTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glGenFramebuffers(1, &c.fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, c.fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, c.fboTex, 0);
        c.fboW = w;
        c.fboH = h;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, c.fbo);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return str(env, "ok=0 err=fbo_incomplete");
    glUseProgram(c.progDump);
    glUniform1f(glGetUniformLocation(c.progDump, "uFlip"), 0.0f);
    glUniform1i(glGetUniformLocation(c.progDump, "uMain"), 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex);
    glDisable(GL_BLEND);

    std::vector<uint8_t> full((size_t)w * h * 4), half((size_t)cw * ch * 4);
    glViewport(0, 0, w, h);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, full.data());
    glViewport(0, 0, cw, ch);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glReadPixels(0, 0, cw, ch, GL_RGBA, GL_UNSIGNED_BYTE, half.data());
    GLenum err = glGetError();

    // Orientation: GL row r <-> buffer row r (flip=0) or h-1-r (flip=1); pick the better one for Y, use it for all.
    int bestFlip = 0;
    Diff yd[2];
    for (int flip = 0; flip < 2; flip++) {
        for (int r = 0; r < h; r += 3) {
            int br = flip ? h - 1 - r : r;
            for (int x = 0; x < w; x++) yd[flip].add(full[((size_t)r * w + x) * 4], Y[(size_t)br * w + x]);
        }
    }
    if (yd[1].mis < yd[0].mis) bestFlip = 1;
    Diff y, cb, cr;
    for (int r = 0; r < h; r++) {
        int br = bestFlip ? h - 1 - r : r;
        for (int x = 0; x < w; x++) y.add(full[((size_t)r * w + x) * 4], Y[(size_t)br * w + x]);
    }
    for (int r = 0; r < ch; r++) {
        int br = bestFlip ? ch - 1 - r : r;
        for (int x = 0; x < cw; x++) {
            cb.add(half[((size_t)r * cw + x) * 4 + 1], U[(size_t)br * cw + x]);
            cr.add(half[((size_t)r * cw + x) * 4 + 2], V[(size_t)br * cw + x]);
        }
    }
    const bool exact = err == GL_NO_ERROR && y.mis == 0 && cb.mis == 0 && cr.mis == 0 && y.total > 0;
    return str(env, fmt("ok=1 exact=%d flip=%d ahb_fmt=0x%x ahb=%ux%u y_mis=%lld/%lld y_max=%d cb_mis=%lld/%lld "
                        "cb_max=%d cr_mis=%lld/%lld cr_max=%d glerr=0x%x",
                        exact ? 1 : 0, bestFlip, desc.format, desc.width, desc.height, y.mis, y.total, y.maxd, cb.mis,
                        cb.total, cb.maxd, cr.mis, cr.total, cr.maxd, err));
}

// ---- presentation ----

// Empty on success, else the failure text. The window surface gets the video's [w] x [h] buffers (the compositor
// scales to the view like it does for the direct path); [swapInterval] 0 = no vsync wait (T-256: no standing queue).
JNIEXPORT jstring JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentInit(
    JNIEnv* env, jclass, jobject surface, jint w, jint h, jint swapInterval) {
    destroy(gPres);
    gPres.reset(new Ctx());
    Ctx& c = *gPres;
    c.width = w;
    c.height = h;
    c.window = ANativeWindow_fromSurface(env, surface);
    std::string err;
    if (!c.window) {
        destroy(gPres);
        return str(env, "no ANativeWindow");
    }
    ANativeWindow_setBuffersGeometry(c.window, w, h, 0);  // best effort; the shader maps by uv either way
    if (!initEgl(c, c.window, err)) {
        std::string e = err;
        destroy(gPres);
        return str(env, e);
    }
    const char* eglExt = eglQueryString(c.dpy, EGL_EXTENSIONS);
    const char* glExt = (const char*)glGetString(GL_EXTENSIONS);
    if (!hasExt(glExt, "GL_EXT_YUV_target")) {
        destroy(gPres);
        return str(env, "GL_EXT_YUV_target not exposed");
    }
    c.progMerge = program(kFsMerge, err);
    if (!c.progMerge) {
        std::string e = "merge:" + err;
        destroy(gPres);
        return str(env, e);
    }
    c.progMain = program(kFsMain, err);
    if (!c.progMain) {
        std::string e = "main:" + err;
        destroy(gPres);
        return str(env, e);
    }
    eglSwapInterval(c.dpy, swapInterval);
    if (pNextFrameId && pFrameTimestamps && hasExt(eglExt, "EGL_ANDROID_get_frame_timestamps")) {
        c.timestamps = eglSurfaceAttrib(c.dpy, c.surf, EGL_TIMESTAMPS_ANDROID, EGL_TRUE) == EGL_TRUE;
        if (c.timestamps && pTsSupported) {
            c.tsRender = pTsSupported(c.dpy, c.surf, EGL_RENDERING_COMPLETE_TIME_ANDROID) == EGL_TRUE;
            c.tsPresent = pTsSupported(c.dpy, c.surf, EGL_DISPLAY_PRESENT_TIME_ANDROID) == EGL_TRUE;
            if (pTsSupported(c.dpy, c.surf, EGL_COMPOSITION_LATCH_TIME_ANDROID) != EGL_TRUE) c.timestamps = false;
        } else {
            c.timestamps = false;  // cannot tell what is supported: do not query
        }
    }
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    // T-261: the state passes. A failure only disables reuse (the single-pass draw keeps working); the text is kept for
    // presentLastError().
    std::string reuseErr;
    if (initReuse(c, reuseErr)) {
        c.reuseOk = true;
    } else {
        c.lastError = "reuse_init:" + reuseErr;
        dropReuse(c);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glViewport(0, 0, w, h);
    }
    return str(env, "");
}

// T-261: the block tolerance in 8-bit steps (video/ChromaReuse.kt TOLERANCE); negative turns reuse off.
JNIEXPORT void JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentSetReuseTolerance(JNIEnv*, jclass, jint tol) {
    if (gPres) gPres->reuseTol = tol;
}

// {same, total} sampled blocks since the last call (reuse_pct = same / total); GL thread only (reads a finished sample).
JNIEXPORT jlongArray JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentReuseStats(JNIEnv* env, jclass) {
    int64_t v[2] = {0, 0};
    if (gPres) {
        pollFences(*gPres);
        pollSample(*gPres);
        v[0] = gPres->reuseSame;
        v[1] = gPres->reuseTotal;
        gPres->reuseSame = 0;
        gPres->reuseTotal = 0;
    }
    jlongArray a = env->NewLongArray(2);
    env->SetLongArrayRegion(a, 0, 2, (const jlong*)v);
    return a;
}

// yOffset, yScale, cScale, crR, cbG, crG, cbB (video/Avc444v2.kt YuvConversion.toArray).
JNIEXPORT void JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentSetConversion(
    JNIEnv* env, jclass, jfloatArray conv) {
    if (!gPres || env->GetArrayLength(conv) < 7) return;
    env->GetFloatArrayRegion(conv, 0, 7, gPres->conv);
}

JNIEXPORT jstring JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentFeatures(JNIEnv* env, jclass) {
    if (!gPres) return str(env, "none");
    return str(env, fmt("frame_timestamps=%d render_ts=%d present_time=%d reuse=%d", (int)gPres->timestamps,
                        (int)(gPres->timestamps && gPres->tsRender), (int)(pPresentationTime != nullptr),
                        (int)(gPres->reuseOk && gPres->reuseTol >= 0)));
}

// Draws main (+ the auxiliary view when [auxHwb] is non-null: the merge pass) and swaps. [presentNs] > 0 sets
// eglPresentationTimeANDROID (monotonic ns) for this swap; [tag] identifies the frame in the timestamp quads.
// Returns 0, or a negative code (see presentLastError).
JNIEXPORT jint JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentDraw(
    JNIEnv* env, jclass, jobject mainHwb, jobject auxHwb, jlong tag, jlong presentNs) {
    if (!gPres) return -1;
    Ctx& c = *gPres;
    pollFences(c);
    pollSample(c);
    if (c.fences.size() > kMaxFences) {
        c.lastError = "fence_backlog";
        return -6;
    }
    AHardwareBuffer* m = AHardwareBuffer_fromHardwareBuffer(env, mainHwb);
    if (!m) {
        c.lastError = "no main ahb";
        return -2;
    }
    GLuint mt = importBuffer(c, m);
    if (!mt) return -3;
    GLuint at = 0;
    if (auxHwb) {
        AHardwareBuffer* a = AHardwareBuffer_fromHardwareBuffer(env, auxHwb);
        if (!a) {
            c.lastError = "no aux ahb";
            return -4;
        }
        at = importBuffer(c, a);
        if (!at) return -4;
    }
    if (c.reuseOk && c.reuseTol >= 0) {
        drawReuse(c, mt, at);
    } else {
        drawDirect(c, mt, at);
    }
    if (presentNs > 0 && pPresentationTime) pPresentationTime(c.dpy, c.surf, (EGLnsecsANDROID)presentNs);
    uint64_t frameId = 0;
    bool haveId = c.timestamps && pNextFrameId(c.dpy, c.surf, &frameId);
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (!fence) glFinish();  // no fence: wait for the GPU here, the draw is complete when the queue entry is popped
    c.fences.push_back(fence);
    c.fencesPushed++;
    glFlush();
    const int64_t submitNs = monotonicNs();
    if (!eglSwapBuffers(c.dpy, c.surf)) {
        c.lastError = fmt("eglSwapBuffers:0x%x", eglGetError());
        return -5;
    }
    if (haveId) {
        c.pendingTs.push_back({frameId, (int64_t)tag, submitNs});
        pollTimestamps(c);
    }
    pollSample(c);
    return 0;
}

// Number of draws (since presentInit) whose GPU work has completed: fences signal in order, so images last used by draw N
// may be closed once this is >= N (a draw that failed before its fence counts as nothing submitted, see Kotlin).
JNIEXPORT jlong JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentCompletedDraws(JNIEnv*, jclass) {
    if (!gPres) return 0;
    Ctx& c = *gPres;
    pollFences(c);
    return (jlong)c.fencesDone;
}

// Swapped frames whose compositor latch time is still unknown (-1: timestamps unavailable, cannot tell).
JNIEXPORT jint JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentOutstanding(JNIEnv*, jclass) {
    if (!gPres || !gPres->timestamps) return -1;
    Ctx& c = *gPres;
    pollTimestamps(c);
    const EGLint names[1] = {EGL_COMPOSITION_LATCH_TIME_ANDROID};
    int outstanding = 0;
    for (const auto& p : c.pendingTs) {
        int64_t v[1] = {0};
        if (!pFrameTimestamps(c.dpy, c.surf, p.id, 1, names, v)) continue;  // history lost it: not waiting
        if (v[0] == EGL_TIMESTAMP_PENDING_ANDROID) outstanding++;
    }
    return outstanding;
}

JNIEXPORT jstring JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentLastError(JNIEnv* env, jclass) {
    return str(env, gPres ? gPres->lastError : std::string("no context"));
}

// Quintuples [tag, latchNs, presentNs, renderCompleteNs, submitNs] of frames resolved since the last call.
JNIEXPORT jlongArray JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentDrainTimestamps(JNIEnv* env, jclass) {
    std::vector<int64_t> v;
    if (gPres) {
        pollTimestamps(*gPres);
        v.swap(gPres->tsOut);
    }
    jlongArray a = env->NewLongArray((jsize)v.size());
    env->SetLongArrayRegion(a, 0, (jsize)v.size(), (const jlong*)v.data());
    return a;
}

JNIEXPORT void JNICALL Java_dev_matebridge_client_video_FullChromaNative_presentShutdown(JNIEnv*, jclass) {
    if (gPres) glFinish();
    destroy(gPres);
}

}  // extern "C"
