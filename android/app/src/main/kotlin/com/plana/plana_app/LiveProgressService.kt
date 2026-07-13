package com.plana.plana_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 生成进度前台服务:切后台不被杀 + 独占一条常驻通知。
 *
 * 分档渲染(能力探测 + 优雅降级):
 *  - API 36+：Notification.ProgressStyle + setRequestPromotedOngoing → 系统可提升到
 *    状态栏胶囊 / 锁屏 / AOD;三星 One UI 8、OPPO ColorOS 16 等灵动岛会自动采纳这套标准。
 *  - 低版本：回落成普通 setProgress 进度条(全版本可见,只是不上岛)。
 *
 * 由 MethodChannel 经 companion 驱动。update/finish/stop 直接操作运行中的实例,
 * 避免"后台 startService"限制;仅 start 用 startForegroundService 拉起。
 * 生成逻辑仍在 Flutter 主 isolate,本服务只负责进程保活与通知。
 */
class LiveProgressService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_START) {
            val title = intent.getStringExtra(EXTRA_TITLE) ?: "Plana"
            val text = intent.getStringExtra(EXTRA_TEXT) ?: "准备生成…"
            startInForeground(build(title, text, 0, 0, indeterminate = true, shortText = "…", ongoing = true))
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    // —— 实例侧:被 companion 直接调用 ——

    fun applyUpdate(
        cur: Int,
        total: Int,
        indeterminate: Boolean,
        title: String,
        text: String,
        shortText: String,
    ) {
        nm().notify(NOTIF_ID, build(title, text, cur, total, indeterminate, shortText, ongoing = true))
    }

    /** 收尾:改成非常驻、可点开的完成/失败态,脱离前台但保留这条通知给用户看。 */
    fun applyFinish(title: String, text: String) {
        nm().notify(NOTIF_ID, build(title, text, 0, 0, indeterminate = false, shortText = "", ongoing = false))
        stopForegroundCompat(removeNotification = false)
        stopSelf()
    }

    /** 静默停止:直接撤掉通知与服务(前台时用,结果已在应用内可见)。 */
    fun applyStop() {
        stopForegroundCompat(removeNotification = true)
        stopSelf()
    }

    // —— 通知构造 ——

    private fun build(
        title: String,
        text: String,
        cur: Int,
        total: Int,
        indeterminate: Boolean,
        shortText: String,
        ongoing: Boolean,
    ): Notification {
        ensureChannel()
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .setContentIntent(pi)

        if (Build.VERSION.SDK_INT >= 36 && ongoing && total > 0 && !indeterminate) {
            // L2:进度中心样式 + 请求提升为 promoted-ongoing → 状态栏胶囊/锁屏(灵动岛)
            val style = NotificationCompat.ProgressStyle()
                .setProgressSegments(listOf(NotificationCompat.ProgressStyle.Segment(total)))
                .setProgress(cur.coerceIn(0, total))
            b.setStyle(style)
            if (shortText.isNotEmpty()) b.setShortCriticalText(shortText)
            b.setRequestPromotedOngoing(true)
        } else {
            // L1:普通进度条(全版本);indeterminate = 转圈
            when {
                indeterminate -> b.setProgress(0, 0, true)
                total > 0 -> b.setProgress(total, cur.coerceIn(0, total), false)
            }
        }
        return b.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = nm()
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            // IMPORTANCE_LOW:静默(不 heads-up、不发声),但高于 MIN,满足上岛门槛
            val ch = NotificationChannel(CHANNEL_ID, "生成进度", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
    }

    private fun nm() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun startInForeground(notif: Notification) {
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun stopForegroundCompat(removeNotification: Boolean) {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(if (removeNotification) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(removeNotification)
        }
    }

    companion object {
        const val CHANNEL_ID = "gen_progress"
        const val NOTIF_ID = 4711
        private const val ACTION_START = "com.plana.plana_app.LIVE_START"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"

        @Volatile
        private var instance: LiveProgressService? = null

        fun start(ctx: Context, title: String?, text: String?) {
            val i = Intent(ctx, LiveProgressService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun update(
            cur: Int,
            total: Int,
            indeterminate: Boolean,
            title: String,
            text: String,
            shortText: String,
        ) {
            instance?.applyUpdate(cur, total, indeterminate, title, text, shortText)
        }

        fun finish(title: String, text: String) {
            instance?.applyFinish(title, text)
        }

        fun stop() {
            instance?.applyStop()
        }

        /** 该设备/权限下能否真正上岛(API 36 promoted)。供 Dart 探测降级。 */
        fun canPromote(ctx: Context): Boolean {
            if (Build.VERSION.SDK_INT < 36) return false
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            return nm.canPostPromotedNotifications()
        }
    }
}
