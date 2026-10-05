// T-254 probe: the GPU half of the 4:4:4 packing gates.
//  - caps():        GL / EGL / Vulkan extension lists (gate 1: GL_EXT_YUV_target, VK_KHR_sampler_ycbcr_conversion).
//  - raw*():        samples a decoder image as raw Y/Cb/Cr through GL_EXT_YUV_target and compares bit-for-bit with
//                   a CPU copy (gate 1: is raw sampling exact?).
//  - present*():    decoder image(s) -> EGLImage -> external textures -> one merge pass -> window surface, with
//                   per-frame EGL timestamps (latch / present) and GPU timer queries (gate 2).
// All GL calls of one context come from one thread (the Kotlin caller's). Logs go to Kotlin as returned strings.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <vulkan/vulkan.h>

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

#define GL_TIME_ELAPSED_EXT_ 0x88BF
#define GL_QUERY_RESULT_EXT_ 0x8866
#define GL_QUERY_RESULT_AVAILABLE_EXT_ 0x8867
#define GL_GPU_DISJOINT_EXT_ 0x8FBB

namespace {

typedef EGLClientBuffer (*PFN_getNativeClientBuffer)(const struct AHardwareBuffer*);
typedef EGLBoolean (*PFN_getNextFrameId)(EGLDisplay, EGLSurface, uint64_t*);
typedef EGLBoolean (*PFN_getFrameTimestamps)(EGLDisplay, EGLSurface, uint64_t, EGLint, const EGLint*, int64_t*);
typedef EGLBoolean (*PFN_presentationTime)(EGLDisplay, EGLSurface, EGLnsecsANDROID);
typedef void (*PFN_genQueries)(GLsizei, GLuint*);
typedef void (*PFN_beginQuery)(GLenum, GLuint);
typedef void (*PFN_endQuery)(GLenum);
typedef void (*PFN_getQueryuiv)(GLuint, GLenum, GLuint*);
typedef void (*PFN_getQueryui64v)(GLuint, GLenum, uint64_t*);

PFN_getNativeClientBuffer pGetNativeClientBuffer;
PFNEGLCREATEIMAGEKHRPROC pCreateImage;
PFNEGLDESTROYIMAGEKHRPROC pDestroyImage;
PFNGLEGLIMAGETARGETTEXTURE2DOESPROC pImageTarget;
PFN_getNextFrameId pNextFrameId;
PFN_getFrameTimestamps pFrameTimestamps;
PFN_presentationTime pPresentationTime;
PFN_genQueries pGenQueries;
PFN_beginQuery pBeginQuery;
PFN_endQuery pEndQuery;
PFN_getQueryuiv pGetQueryuiv;
PFN_getQueryui64v pGetQueryui64v;

void loadProcs() {
    pGetNativeClientBuffer = (PFN_getNativeClientBuffer)eglGetProcAddress("eglGetNativeClientBufferANDROID");
    pCreateImage = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    pDestroyImage = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    pImageTarget = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    pNextFrameId = (PFN_getNextFrameId)eglGetProcAddress("eglGetNextFrameIdANDROID");
    pFrameTimestamps = (PFN_getFrameTimestamps)eglGetProcAddress("eglGetFrameTimestampsANDROID");
    pPresentationTime = (PFN_presentationTime)eglGetProcAddress("eglPresentationTimeANDROID");
    pGenQueries = (PFN_genQueries)eglGetProcAddress("glGenQueriesEXT");
    pBeginQuery = (PFN_beginQuery)eglGetProcAddress("glBeginQueryEXT");
    pEndQuery = (PFN_endQuery)eglGetProcAddress("glEndQueryEXT");
    pGetQueryuiv = (PFN_getQueryuiv)eglGetProcAddress("glGetQueryObjectuivEXT");
    pGetQueryui64v = (PFN_getQueryui64v)eglGetProcAddress("glGetQueryObjectui64vEXT");
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
};

struct Ctx {
    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLContext ctx = EGL_NO_CONTEXT;
    EGLSurface surf = EGL_NO_SURFACE;
    ANativeWindow* window = nullptr;
    std::unordered_map<AHardwareBuffer*, Imported> cache;
    GLuint progs[3] = {0, 0, 0};
    GLuint vao = 0;
    GLuint fbo = 0, fboTex = 0;
    int fboW = 0, fboH = 0;
    // present state
    int mode = 2;  // 0 oes, 1 raw main, 2 raw merge
    struct Pending {
        uint64_t id;
        int64_t queuedNs;
    };
    std::deque<Pending> pendingTs;
    std::vector<int64_t> tsOut;  // quads: queued, latch, present, rendering complete
    std::deque<GLuint> pendingQueries;
    std::vector<GLuint> freeQueries;
    std::vector<int64_t> gpuOut;
    bool timer = false;
    bool timestamps = false;
    std::string lastError;
    int draws = 0;
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

const char* kFsOes = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
uniform samplerExternalOES uMain;
in vec2 vUv;
out vec4 o;
void main() { o = texture(uMain, vUv); }
)";

// Raw (unconverted) Y/Cb/Cr, full-range BT.709 conversion in the shader.
const char* kFsRawMain = R"(#version 300 es
#extension GL_EXT_YUV_target : require
precision highp float;
uniform __samplerExternal2DY2YEXT uMain;
in vec2 vUv;
out vec4 o;
void main() {
  vec3 m = texture(uMain, vUv).rgb;
  float cb = m.g - 0.5, cr = m.b - 0.5;
  o = vec4(m.r + 1.5748 * cr, m.r - 0.1873 * cb - 0.4681 * cr, m.r + 1.8556 * cb, 1.0);
}
)";

// Raw bit-exact dump: R = Y, G = Cb, B = Cr (no conversion).
const char* kFsRawDump = R"(#version 300 es
#extension GL_EXT_YUV_target : require
precision highp float;
uniform __samplerExternal2DY2YEXT uMain;
in vec2 vUv;
out vec4 o;
void main() { o = vec4(texture(uMain, vUv).rgb, 1.0); }
)";

// Cost-equivalent stand-in for the AVC444v2 merge (two raw YUV fetches, parity select, conversion). The real
// inverse mapping is a product task; this probe only measures memory traffic and ALU of a two-image pass.
const char* kFsMerge = R"(#version 300 es
#extension GL_EXT_YUV_target : require
precision highp float;
uniform __samplerExternal2DY2YEXT uMain;
uniform __samplerExternal2DY2YEXT uAux;
in vec2 vUv;
out vec4 o;
void main() {
  vec3 m = texture(uMain, vUv).rgb;
  vec3 a = texture(uAux, vUv).rgb;
  bool odd = ((int(gl_FragCoord.x) + int(gl_FragCoord.y)) & 1) == 1;
  float cb = (odd ? a.g : m.g) - 0.5;
  float cr = (odd ? a.b : m.b) - 0.5;
  float y = m.r + 0.0 * a.r;
  o = vec4(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb, 1.0);
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
        for (auto& ch : err) if (ch == '\n') ch = ' ';
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
    if (!pGetNativeClientBuffer || !pCreateImage || !pImageTarget) {
        err = "missing EGL_ANDROID_get_native_client_buffer / EGL_KHR_image_base entry points";
        return false;
    }
    glGenVertexArrays(1, &c.vao);
    glBindVertexArray(c.vao);
    return true;
}

GLuint importBuffer(Ctx& c, AHardwareBuffer* ahb) {
    auto it = c.cache.find(ahb);
    if (it != c.cache.end()) return it->second.tex;
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
    c.cache[ahb] = {img, tex};
    return tex;
}

void destroy(std::unique_ptr<Ctx>& p) {
    if (!p) return;
    Ctx& c = *p;
    if (c.dpy != EGL_NO_DISPLAY && c.ctx != EGL_NO_CONTEXT && c.surf != EGL_NO_SURFACE) {
        eglMakeCurrent(c.dpy, c.surf, c.surf, c.ctx);
        for (auto& kv : c.cache) {
            glDeleteTextures(1, &kv.second.tex);
            if (pDestroyImage) pDestroyImage(c.dpy, kv.second.image);
        }
        for (GLuint pr : c.progs) if (pr) glDeleteProgram(pr);
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

void pollGpu(Ctx& c) {
    while (!c.pendingQueries.empty()) {
        GLuint q = c.pendingQueries.front();
        GLuint avail = 0;
        pGetQueryuiv(q, GL_QUERY_RESULT_AVAILABLE_EXT_, &avail);
        if (!avail) break;
        uint64_t ns = 0;
        pGetQueryui64v(q, GL_QUERY_RESULT_EXT_, &ns);
        GLint disjoint = 0;
        glGetIntegerv(GL_GPU_DISJOINT_EXT_, &disjoint);
        if (!disjoint) c.gpuOut.push_back((int64_t)ns);
        c.pendingQueries.pop_front();
        c.freeQueries.push_back(q);
    }
}

void pollTimestamps(Ctx& c) {
    const EGLint names[3] = {EGL_RENDERING_COMPLETE_TIME_ANDROID, EGL_COMPOSITION_LATCH_TIME_ANDROID,
                             EGL_DISPLAY_PRESENT_TIME_ANDROID};
    while (!c.pendingTs.empty()) {
        auto p = c.pendingTs.front();
        int64_t v[3] = {0, 0, 0};
        if (!pFrameTimestamps(c.dpy, c.surf, p.id, 3, names, v)) {
            c.pendingTs.pop_front();  // history no longer holds this frame
            continue;
        }
        if (v[1] == EGL_TIMESTAMP_PENDING_ANDROID || v[2] == EGL_TIMESTAMP_PENDING_ANDROID) {
            if (c.pendingTs.size() > 6) {
                c.pendingTs.pop_front();  // too far behind: give up on the oldest
                continue;
            }
            break;
        }
        c.tsOut.push_back(p.queuedNs);
        c.tsOut.push_back(v[1]);
        c.tsOut.push_back(v[2]);
        c.tsOut.push_back(v[0]);
        c.pendingTs.pop_front();
    }
}

}  // namespace

extern "C" {

JNIEXPORT jstring JNICALL Java_dev_matebridge_yuv444probe_Native_caps(JNIEnv* env, jclass) {
    std::string out;
    {
        std::unique_ptr<Ctx> c(new Ctx());
        std::string err;
        if (!initEgl(*c, nullptr, err)) {
            out += "gl_init=fail:" + err + "\n";
        } else {
            const char* eglExt = eglQueryString(c->dpy, EGL_EXTENSIONS);
            const char* glExt = (const char*)glGetString(GL_EXTENSIONS);
            out += fmt("gl_vendor=%s\ngl_renderer=%s\ngl_version=%s\nglsl_version=%s\n",
                       (const char*)glGetString(GL_VENDOR), (const char*)glGetString(GL_RENDERER),
                       (const char*)glGetString(GL_VERSION), (const char*)glGetString(GL_SHADING_LANGUAGE_VERSION));
            out += fmt("gl_EXT_YUV_target=%d\n", hasExt(glExt, "GL_EXT_YUV_target"));
            out += fmt("gl_OES_EGL_image_external_essl3=%d\n", hasExt(glExt, "GL_OES_EGL_image_external_essl3"));
            out += fmt("gl_OES_EGL_image_external=%d\n", hasExt(glExt, "GL_OES_EGL_image_external"));
            out += fmt("gl_EXT_disjoint_timer_query=%d\n", hasExt(glExt, "GL_EXT_disjoint_timer_query"));
            out += fmt("egl_ANDROID_get_native_client_buffer=%d\n",
                       hasExt(eglExt, "EGL_ANDROID_get_native_client_buffer"));
            out += fmt("egl_ANDROID_image_native_buffer=%d\n", hasExt(eglExt, "EGL_ANDROID_image_native_buffer"));
            out += fmt("egl_ANDROID_get_frame_timestamps=%d\n", hasExt(eglExt, "EGL_ANDROID_get_frame_timestamps"));
            out += fmt("egl_ANDROID_presentation_time=%d\n", hasExt(eglExt, "EGL_ANDROID_presentation_time"));
            out += fmt("egl_ANDROID_native_fence_sync=%d\n", hasExt(eglExt, "EGL_ANDROID_native_fence_sync"));
            out += fmt("egl_KHR_image_base=%d\n", hasExt(eglExt, "EGL_KHR_image_base"));
            out += std::string("gl_extensions_all=") + (glExt ? glExt : "") + "\n";
            out += std::string("egl_extensions_all=") + (eglExt ? eglExt : "") + "\n";
        }
        std::unique_ptr<Ctx> tmp = std::move(c);
        destroy(tmp);
    }
    // Vulkan
    VkApplicationInfo app = {};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "y444probe";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici = {};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    VkInstance inst = VK_NULL_HANDLE;
    VkResult r = vkCreateInstance(&ici, nullptr, &inst);
    if (r != VK_SUCCESS) {
        out += fmt("vk_instance=fail:%d\n", (int)r);
    } else {
        uint32_t n = 0;
        vkEnumeratePhysicalDevices(inst, &n, nullptr);
        std::vector<VkPhysicalDevice> devs(n);
        vkEnumeratePhysicalDevices(inst, &n, devs.data());
        out += fmt("vk_devices=%u\n", n);
        for (uint32_t i = 0; i < n; i++) {
            VkPhysicalDeviceProperties pr;
            vkGetPhysicalDeviceProperties(devs[i], &pr);
            uint32_t en = 0;
            vkEnumerateDeviceExtensionProperties(devs[i], nullptr, &en, nullptr);
            std::vector<VkExtensionProperties> exts(en);
            vkEnumerateDeviceExtensionProperties(devs[i], nullptr, &en, exts.data());
            std::string all;
            auto has = [&](const char* name) {
                for (auto& e : exts) if (strcmp(e.extensionName, name) == 0) return true;
                return false;
            };
            for (auto& e : exts) all += std::string(e.extensionName) + " ";
            VkPhysicalDeviceSamplerYcbcrConversionFeatures yf = {};
            yf.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES;
            VkPhysicalDeviceFeatures2 f2 = {};
            f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
            f2.pNext = &yf;
            vkGetPhysicalDeviceFeatures2(devs[i], &f2);
            out += fmt("vk%u_name=%s\nvk%u_api=%u.%u.%u\nvk%u_ycbcr_feature=%d\n"
                       "vk%u_ext_KHR_sampler_ycbcr_conversion=%d\n",
                       i, pr.deviceName, i, VK_VERSION_MAJOR(pr.apiVersion), VK_VERSION_MINOR(pr.apiVersion),
                       VK_VERSION_PATCH(pr.apiVersion), i, (int)yf.samplerYcbcrConversion, i,
                       (int)has("VK_KHR_sampler_ycbcr_conversion"));
            out += fmt("vk%u_ext_ANDROID_external_memory_android_hardware_buffer=%d\nvk%u_ext_GOOGLE_display_timing=%d\n"
                       "vk%u_ext_EXT_queue_family_foreign=%d\n",
                       i, (int)has("VK_ANDROID_external_memory_android_hardware_buffer"), i,
                       (int)has("VK_GOOGLE_display_timing"), i, (int)has("VK_EXT_queue_family_foreign"));
            out += fmt("vk%u_extensions_all=", i) + all + "\n";
        }
        vkDestroyInstance(inst, nullptr);
    }
    return str(env, out);
}

// ---- raw sampling comparison ----

JNIEXPORT jstring JNICALL Java_dev_matebridge_yuv444probe_Native_rawInit(JNIEnv* env, jclass) {
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
    GLuint p = program(kFsRawDump, err);
    if (!p) {
        std::string e = err;
        destroy(gRaw);
        return str(env, e);
    }
    gRaw->progs[0] = p;
    return str(env, "");
}

JNIEXPORT void JNICALL Java_dev_matebridge_yuv444probe_Native_rawShutdown(JNIEnv*, jclass) { destroy(gRaw); }

// Renders the raw Y/Cb/Cr of [hwb] twice: full resolution (compares Y) and half resolution at chroma texel centres
// (compares Cb, Cr exactly); also reports how the driver upsampled chroma at full resolution. Planes are tightly packed.
JNIEXPORT jstring JNICALL Java_dev_matebridge_yuv444probe_Native_rawCompare(
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
    glUseProgram(c.progs[0]);
    glUniform1f(glGetUniformLocation(c.progs[0], "uFlip"), 0.0f);
    glUniform1i(glGetUniformLocation(c.progs[0], "uMain"), 0);
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
        for (int r = 0; r < h; r += 7) {
            int br = flip ? h - 1 - r : r;
            for (int x = 0; x < w; x++) yd[flip].add(full[((size_t)r * w + x) * 4], Y[(size_t)br * w + x]);
        }
    }
    if (yd[1].mis < yd[0].mis) bestFlip = 1;
    Diff y, cb, cr, upCb, upCr;
    for (int r = 0; r < h; r++) {
        int br = bestFlip ? h - 1 - r : r;
        for (int x = 0; x < w; x++) {
            y.add(full[((size_t)r * w + x) * 4], Y[(size_t)br * w + x]);
            size_t ci = (size_t)(br / 2) * cw + x / 2;
            upCb.add(full[((size_t)r * w + x) * 4 + 1], U[ci]);
            upCr.add(full[((size_t)r * w + x) * 4 + 2], V[ci]);
        }
    }
    for (int r = 0; r < ch; r++) {
        int br = bestFlip ? ch - 1 - r : r;
        for (int x = 0; x < cw; x++) {
            cb.add(half[((size_t)r * cw + x) * 4 + 1], U[(size_t)br * cw + x]);
            cr.add(half[((size_t)r * cw + x) * 4 + 2], V[(size_t)br * cw + x]);
        }
    }
    return str(env, fmt("ok=1 flip=%d ahb_fmt=0x%x ahb=%ux%u y_mis=%lld/%lld y_max=%d cb_mis=%lld/%lld cb_max=%d "
                        "cr_mis=%lld/%lld cr_max=%d fullres_cb_mis=%lld/%lld fullres_cr_mis=%lld/%lld glerr=0x%x",
                        bestFlip, desc.format, desc.width, desc.height, y.mis, y.total, y.maxd, cb.mis, cb.total,
                        cb.maxd, cr.mis, cr.total, cr.maxd, upCb.mis, upCb.total, upCr.mis, upCr.total, err));
}

// ---- presentation ----

// mode: 0 = driver-converted samplerExternalOES, 1 = raw main + conversion, 2 = raw main + aux merge.
// Returns "" or the failure text.
JNIEXPORT jstring JNICALL Java_dev_matebridge_yuv444probe_Native_presentInit(
    JNIEnv* env, jclass, jobject surface, jint w, jint h, jint mode, jint swapInterval) {
    destroy(gPres);
    gPres.reset(new Ctx());
    Ctx& c = *gPres;
    c.mode = mode;
    c.window = ANativeWindow_fromSurface(env, surface);
    std::string err;
    if (!c.window) {
        destroy(gPres);
        return str(env, "no ANativeWindow");
    }
    if (!initEgl(c, c.window, err)) {
        std::string e = err;
        destroy(gPres);
        return str(env, e);
    }
    const char* eglExt = eglQueryString(c.dpy, EGL_EXTENSIONS);
    const char* glExt = (const char*)glGetString(GL_EXTENSIONS);
    const char* fs = mode == 0 ? kFsOes : mode == 1 ? kFsRawMain : kFsMerge;
    c.progs[mode] = program(fs, err);
    if (!c.progs[mode]) {
        std::string e = err;
        destroy(gPres);
        return str(env, e);
    }
    eglSwapInterval(c.dpy, swapInterval);
    if (pNextFrameId && pFrameTimestamps && hasExt(eglExt, "EGL_ANDROID_get_frame_timestamps")) {
        c.timestamps = eglSurfaceAttrib(c.dpy, c.surf, EGL_TIMESTAMPS_ANDROID, EGL_TRUE) == EGL_TRUE;
    }
    if (hasExt(glExt, "GL_EXT_disjoint_timer_query") && pGenQueries && pBeginQuery && pEndQuery && pGetQueryuiv &&
        pGetQueryui64v) {
        c.timer = true;
        GLuint q[8];
        pGenQueries(8, q);
        c.freeQueries.assign(q, q + 8);
    }
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    return str(env, "");
}

JNIEXPORT jstring JNICALL Java_dev_matebridge_yuv444probe_Native_presentFeatures(JNIEnv* env, jclass) {
    if (!gPres) return str(env, "none");
    return str(env, fmt("frame_timestamps=%d gpu_timer=%d present_time=%d", (int)gPres->timestamps, (int)gPres->timer, (int)(pPresentationTime != nullptr)));
}

// Draws main (+ aux when mode 2) and swaps. Returns 0, or a negative code (see presentLastError).
JNIEXPORT jint JNICALL Java_dev_matebridge_yuv444probe_Native_presentDraw(
    JNIEnv* env, jclass, jobject mainHwb, jobject auxHwb, jlong queuedNs, jlong presentNs) {
    if (!gPres) return -1;
    Ctx& c = *gPres;
    AHardwareBuffer* m = AHardwareBuffer_fromHardwareBuffer(env, mainHwb);
    if (!m) {
        c.lastError = "no main ahb";
        return -2;
    }
    GLuint mt = importBuffer(c, m);
    if (!mt) return -3;
    GLuint at = 0;
    if (c.mode == 2) {
        AHardwareBuffer* a = auxHwb ? AHardwareBuffer_fromHardwareBuffer(env, auxHwb) : nullptr;
        // Without an aux image yet, the merge pass samples main twice (same pass shape, no extra buffer).
        at = a ? importBuffer(c, a) : mt;
        if (!at) return -4;
    }
    GLuint p = c.progs[c.mode];
    glUseProgram(p);
    glUniform1f(glGetUniformLocation(p, "uFlip"), 1.0f);
    glUniform1i(glGetUniformLocation(p, "uMain"), 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, mt);
    if (c.mode == 2) {
        glUniform1i(glGetUniformLocation(p, "uAux"), 1);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_EXTERNAL_OES, at);
        glActiveTexture(GL_TEXTURE0);
    }
    GLuint q = 0;
    if (c.timer && !c.freeQueries.empty()) {
        q = c.freeQueries.back();
        c.freeQueries.pop_back();
        pBeginQuery(GL_TIME_ELAPSED_EXT_, q);
    }
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    if (q) {
        pEndQuery(GL_TIME_ELAPSED_EXT_);
        c.pendingQueries.push_back(q);
    }
    if (presentNs > 0 && pPresentationTime) pPresentationTime(c.dpy, c.surf, (EGLnsecsANDROID)presentNs);
    uint64_t frameId = 0;
    bool haveId = c.timestamps && pNextFrameId(c.dpy, c.surf, &frameId);
    if (!eglSwapBuffers(c.dpy, c.surf)) {
        c.lastError = fmt("eglSwapBuffers:0x%x", eglGetError());
        return -5;
    }
    c.draws++;
    if (haveId) {
        c.pendingTs.push_back({frameId, (int64_t)queuedNs});
        pollTimestamps(c);
    }
    if (c.timer) pollGpu(c);
    return 0;
}

// Swapped frames whose compositor latch time is still unknown (-1: timestamps unavailable, cannot tell).
JNIEXPORT jint JNICALL Java_dev_matebridge_yuv444probe_Native_presentOutstanding(JNIEnv*, jclass) {
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

JNIEXPORT jstring JNICALL Java_dev_matebridge_yuv444probe_Native_presentLastError(JNIEnv* env, jclass) {
    return str(env, gPres ? gPres->lastError : std::string("no context"));
}

// Quads [queuedNs, latchNs, presentNs, renderCompleteNs] of frames resolved since the last call.
JNIEXPORT jlongArray JNICALL Java_dev_matebridge_yuv444probe_Native_presentDrainTimestamps(JNIEnv* env, jclass) {
    std::vector<int64_t> v;
    if (gPres) v.swap(gPres->tsOut);
    jlongArray a = env->NewLongArray((jsize)v.size());
    env->SetLongArrayRegion(a, 0, (jsize)v.size(), (const jlong*)v.data());
    return a;
}

JNIEXPORT jlongArray JNICALL Java_dev_matebridge_yuv444probe_Native_presentDrainGpuNs(JNIEnv* env, jclass) {
    std::vector<int64_t> v;
    if (gPres) v.swap(gPres->gpuOut);
    jlongArray a = env->NewLongArray((jsize)v.size());
    env->SetLongArrayRegion(a, 0, (jsize)v.size(), (const jlong*)v.data());
    return a;
}

JNIEXPORT void JNICALL Java_dev_matebridge_yuv444probe_Native_presentShutdown(JNIEnv*, jclass) {
    if (gPres) glFinish();
    destroy(gPres);
}

}  // extern "C"
