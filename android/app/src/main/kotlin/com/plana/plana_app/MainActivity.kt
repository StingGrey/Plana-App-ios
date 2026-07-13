package com.plana.plana_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // 本地超分固定在单一后台线程执行:ncnn 的 OpenMP(kmp)在不同 pthread 反复 fork 会 SIGABRT。
    private val upscaleExecutor =
        java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        LiveProgressService.start(
                            this,
                            call.argument("title"),
                            call.argument("text"),
                        )
                        result.success(null)
                    }

                    "update" -> {
                        LiveProgressService.update(
                            call.argument<Int>("cur") ?: 0,
                            call.argument<Int>("total") ?: 0,
                            call.argument<Boolean>("indeterminate") ?: false,
                            call.argument<String>("title") ?: "Plana",
                            call.argument<String>("text") ?: "",
                            call.argument<String>("short") ?: "",
                        )
                        result.success(null)
                    }

                    "finish" -> {
                        LiveProgressService.finish(
                            call.argument<String>("title") ?: "Plana",
                            call.argument<String>("text") ?: "",
                        )
                        result.success(null)
                    }

                    "stop" -> {
                        LiveProgressService.stop()
                        result.success(null)
                    }

                    "capabilities" -> result.success(
                        mapOf(
                            "sdkInt" to Build.VERSION.SDK_INT,
                            "canPromote" to LiveProgressService.canPromote(this),
                        ),
                    )

                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
                        }
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // 本地超分(ncnn-vulkan):在后台线程调 native,避免阻塞 UI 线程
        val upscaleChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "plana/upscale")
        upscaleChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "upscale" -> {
                        val png = call.argument<ByteArray>("png")
                        val param = call.argument<String>("param")
                        val bin = call.argument<String>("bin")
                        val scale = call.argument<Int>("scale") ?: 4
                        val tile = call.argument<Int>("tile") ?: 200
                        val pad = call.argument<Int>("prepadding") ?: 10
                        if (png == null || param == null || bin == null) {
                            result.error("bad_args", "missing png/param/bin", null)
                            return@setMethodCallHandler
                        }
                        upscaleExecutor.execute {
                            // 每完成一个 tile,native 回调 UpscaleNative.onProgress → 转发到 Dart(progress)
                            UpscaleNative.progressSink = { cur, total ->
                                runOnUiThread {
                                    upscaleChannel.invokeMethod(
                                        "progress",
                                        mapOf("cur" to cur, "total" to total),
                                    )
                                }
                            }
                            val out = try {
                                UpscaleNative.upscale(png, param, bin, scale, tile, pad)
                            } catch (e: Throwable) {
                                null
                            } finally {
                                UpscaleNative.progressSink = null
                            }
                            runOnUiThread {
                                if (out != null) result.success(out)
                                else result.error("upscale_failed", "native returned null", null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "plana/live_progress"
    }
}
