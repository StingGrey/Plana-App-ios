package com.sora214.plana.app

/// Real-ESRGAN ncnn-vulkan 本地超分的 native 入口(libplana_upscale.so)。
object UpscaleNative {
    init { System.loadLibrary("plana_upscale") }

    /// PNG 字节 → 超分后 PNG 字节;失败返回 null。paramPath/binPath 为 ncnn 模型文件路径。
    external fun upscale(
        png: ByteArray,
        paramPath: String,
        binPath: String,
        scale: Int,
        tilesize: Int,
        prepadding: Int,
    ): ByteArray?

    /// UI 层在发起超分前设置此 sink 接收 (cur, total) tile 进度,完成后置空。
    /// native 在超分后台线程回调,故用 @Volatile 保证跨线程可见。
    @Volatile
    var progressSink: ((Int, Int) -> Unit)? = null

    /// 由 native(JNI)按 tile 进度回调;转交当前 [progressSink]。签名须与 JNI 端 "(II)V" 一致。
    @JvmStatic
    fun onProgress(cur: Int, total: Int) {
        progressSink?.invoke(cur, total)
    }
}
