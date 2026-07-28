// Real-ESRGAN ncnn-vulkan 的 JNI 桥:PNG 字节进 → stb 解码 → realesrgan 超分 → stb 编码 → PNG 出。
#include <jni.h>
#include <android/log.h>
#include <mutex>
#include <string>
#include <vector>

#include "realesrgan.h"
#include "gpu.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "PlanaUpscale", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "PlanaUpscale", __VA_ARGS__)

static std::once_flag g_gpu_once;
static void ensure_gpu() {
    std::call_once(g_gpu_once, []() {
        ncnn::create_gpu_instance();
        LOGI("gpu instance created, count=%d", ncnn::get_gpu_count());
    });
}

// stb_write 回调:把编码字节追加进 vector
static void write_cb(void* ctx, void* data, int size) {
    auto* v = reinterpret_cast<std::vector<unsigned char>*>(ctx);
    auto* p = reinterpret_cast<unsigned char*>(data);
    v->insert(v->end(), p, p + size);
}

// 进度蹦床:native 每完成一个 tile 经此回调 Kotlin 静态 UpscaleNative.onProgress(cur,total)。
// 回调发生在 upscale 的 JNI 调用线程(process 同步执行),可直接复用传入的 env。
struct ProgressCtx {
    JNIEnv* env;
    jclass clazz;
    jmethodID mid;
};
static void progress_trampoline(int cur, int total, void* ud) {
    auto* ctx = reinterpret_cast<ProgressCtx*>(ud);
    if (!ctx || !ctx->mid) return;
    ctx->env->CallStaticVoidMethod(ctx->clazz, ctx->mid, cur, total);
    if (ctx->env->ExceptionCheck()) ctx->env->ExceptionClear();
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_sora214_plana_app_UpscaleNative_upscale(
        JNIEnv* env, jobject /*self*/, // Kotlin object 实例方法:第二参是 INSTANCE,非 jclass
        jbyteArray pngIn, jstring paramPath, jstring binPath,
        jint scale, jint tilesize, jint prepadding) {
    ensure_gpu();
    if (ncnn::get_gpu_count() <= 0) { LOGE("no vulkan gpu"); return nullptr; }

    // 解码 PNG → RGB
    jsize inLen = env->GetArrayLength(pngIn);
    jbyte* inBuf = env->GetByteArrayElements(pngIn, nullptr);
    int w = 0, h = 0, c = 0;
    unsigned char* rgb = stbi_load_from_memory(
            reinterpret_cast<const unsigned char*>(inBuf), inLen, &w, &h, &c, 3);
    env->ReleaseByteArrayElements(pngIn, inBuf, JNI_ABORT);
    if (!rgb) { LOGE("stbi decode failed"); return nullptr; }

    const char* pp = env->GetStringUTFChars(paramPath, nullptr);
    const char* bp = env->GetStringUTFChars(binPath, nullptr);

    jbyteArray result = nullptr;
    {
        RealESRGAN re(0, false);
        if (re.load(std::string(pp), std::string(bp)) != 0) {
            LOGE("model load failed: %s", pp);
        }
        re.scale = scale;
        re.tilesize = tilesize;
        re.prepadding = prepadding;

        // 装配进度回调:每完成一个 tile → Kotlin UpscaleNative.onProgress(cur,total)。
        // 用 FindClass 取真 jclass(不能用第二参,它是 object 实例 jobject)。取不到就不报进度、不崩。
        jclass upscaleCls = env->FindClass("com/sora214/plana/app/UpscaleNative");
        if (env->ExceptionCheck()) env->ExceptionClear();
        jmethodID onProg = upscaleCls
                ? env->GetStaticMethodID(upscaleCls, "onProgress", "(II)V")
                : nullptr;
        if (env->ExceptionCheck()) env->ExceptionClear();
        ProgressCtx pctx{env, upscaleCls, onProg};
        re.progress_cb = (upscaleCls && onProg) ? progress_trampoline : nullptr;
        re.progress_userdata = &pctx;

        // packed RGB uint8:elemsize=3, elempack=3(对齐 main.cpp 的 Mat(w,h,data,c,c))
        ncnn::Mat inMat(w, h, (void*)rgb, (size_t)3, 3);
        ncnn::Mat outMat(w * scale, h * scale, (size_t)3, 3);

        LOGI("process %dx%d -> %dx%d scale=%d tile=%d pad=%d",
             w, h, w * scale, h * scale, scale, tilesize, prepadding);
        int ret = re.process(inMat, outMat);
        LOGI("process ret=%d", ret);

        std::vector<unsigned char> png;
        stbi_write_png_to_func(write_cb, &png, w * scale, h * scale, 3,
                               outMat.data, (w * scale) * 3);

        result = env->NewByteArray((jsize)png.size());
        env->SetByteArrayRegion(result, 0, (jsize)png.size(),
                                reinterpret_cast<const jbyte*>(png.data()));
    }

    env->ReleaseStringUTFChars(paramPath, pp);
    env->ReleaseStringUTFChars(binPath, bp);
    stbi_image_free(rgb);
    return result;
}
