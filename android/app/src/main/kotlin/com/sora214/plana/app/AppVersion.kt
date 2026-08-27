package com.sora214.plana.app

import android.app.Activity
import android.os.Build

/**
 * 读已安装包的真实版本号,供"检查更新"比对用。
 *
 * 为什么不用 Dart 侧的 `kAppVersion` 常量:那是手抄 pubspec 的,只用来显示时
 * 抄错顶多难看;一旦拿它判断"要不要更新",抄错就是全员误判 —— 要么反复提示
 * 已装的版本,要么永远不提示。系统里的版本号是安装器写进去的,不可能对不上。
 *
 * 本应用**不自己装包**:检查到新版只把用户送去 GitHub Release 页,下载与安装
 * 交给浏览器和系统。因此这里既不需要 `REQUEST_INSTALL_PACKAGES`,也不需要
 * FileProvider。
 */
object AppVersion {

    /** 已安装的 versionName(= pubspec 的 `version:` 前半段,如 `1.0.0-beta.1`)。 */
    fun name(activity: Activity): String =
        activity.packageManager.getPackageInfo(activity.packageName, 0).versionName ?: ""

    /** 已安装的 versionCode(= pubspec 的 `+N`)。 */
    fun code(activity: Activity): Long {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }
}
