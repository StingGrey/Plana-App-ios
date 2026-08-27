#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "错误：iOS 工程必须在 macOS 上准备。" >&2
  exit 1
fi
if ! command -v flutter >/dev/null 2>&1; then
  echo "错误：找不到 Flutter。请先安装 Flutter 3.44 或更新版本。" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：找不到 Xcode Command Line Tools。请先安装并启动一次 Xcode。" >&2
  exit 1
fi

# 用本机 Flutter 的模板生成 Xcode 工程，避免把某个旧版 Flutter 的 pbxproj
# 硬塞进仓库。仅生成 iOS，不会重建或覆盖 Android 平台代码。
if [[ ! -f ios/Runner.xcodeproj/project.pbxproj ]]; then
  flutter create \
    --platforms=ios \
    --org com.sora214 \
    --project-name plana_app \
    .
fi

# Flutter 工程不入库,每次生成后注入 Plana 的 AppDelegate。这里负责 iPad
# 外部图片拖放,并把原始字节交给 Dart 侧现有导入面板。
APP_DELEGATE_TEMPLATE="$ROOT/tool/ios/AppDelegate.swift"
SCENE_DELEGATE_TEMPLATE="$ROOT/tool/ios/SceneDelegate.swift"
if [[ ! -f "$APP_DELEGATE_TEMPLATE" || ! -f "$SCENE_DELEGATE_TEMPLATE" ]]; then
  echo "错误：找不到 iOS 生命周期模板。" >&2
  exit 1
fi
cp "$APP_DELEGATE_TEMPLATE" ios/Runner/AppDelegate.swift
cp "$SCENE_DELEGATE_TEMPLATE" ios/Runner/SceneDelegate.swift

PLIST="ios/Runner/Info.plist"
PB="/usr/libexec/PlistBuddy"
if [[ ! -f "$PLIST" || ! -x "$PB" ]]; then
  echo "错误：iOS 工程生成不完整，找不到 Info.plist 或 PlistBuddy。" >&2
  exit 1
fi

plist_string() {
  local key="$1" value="$2"
  "$PB" -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
  "$PB" -c "Add :$key string \"$value\"" "$PLIST"
}
plist_bool() {
  local key="$1" value="$2"
  "$PB" -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
  "$PB" -c "Add :$key bool $value" "$PLIST"
}

plist_string "CFBundleDisplayName" "Plana App"
plist_string "NSPhotoLibraryUsageDescription" "用于选择参考图、Vibe 与待导入的图片，并保留原始生成参数。"
plist_string "NSPhotoLibraryAddUsageDescription" "用于把生成或处理后的图片保存到系统照片。"
plist_string "NSLocalNetworkUsageDescription" "用于连接你在设置中填写的局域网 Plana 后端。"
plist_bool "LSSupportsOpeningDocumentsInPlace" true
# 本应用只使用系统 TLS、Keychain 与标准密码派生，没有自研或非豁免加密出口。
plist_bool "ITSAppUsesNonExemptEncryption" false

# 只放行本地网络，不为公网请求全局关闭 ATS。
"$PB" -c "Add :NSAppTransportSecurity dict" "$PLIST" >/dev/null 2>&1 || true
"$PB" -c "Delete :NSAppTransportSecurity:NSAllowsLocalNetworking" "$PLIST" >/dev/null 2>&1 || true
"$PB" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PLIST"

# 这些插件均支持 iOS 13；统一 Runner、测试 target 与 Flutter framework 的下限。
if [[ -f ios/Podfile ]]; then
  if grep -Eq '^#?platform :ios' ios/Podfile; then
    sed -i '' -E "s/^#?platform :ios, .*/platform :ios, '13.0'/" ios/Podfile
  else
    printf "platform :ios, '13.0'\n\n" | cat - ios/Podfile > ios/Podfile.tmp
    mv ios/Podfile.tmp ios/Podfile
  fi
fi
PBX="ios/Runner.xcodeproj/project.pbxproj"
if [[ -f "$PBX" ]]; then
  perl -0pi -e 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/g; s/com\.sora214\.planaApp/com.sora214.plana.app/g; s/com\.sora214\.plana_app/com.sora214.plana.app/g' "$PBX"
fi
FRAMEWORK_PLIST="ios/Flutter/AppFrameworkInfo.plist"
if [[ -f "$FRAMEWORK_PLIST" ]]; then
  "$PB" -c "Set :MinimumOSVersion 13.0" "$FRAMEWORK_PLIST" >/dev/null 2>&1 || true
fi

flutter pub get
dart run flutter_launcher_icons

if [[ -f ios/Podfile ]]; then
  if ! command -v pod >/dev/null 2>&1; then
    echo "错误：此 Flutter 工程使用 CocoaPods，但系统找不到 pod。" >&2
    echo "可先执行：brew install cocoapods" >&2
    exit 1
  fi
  (
    cd ios
    pod install
  )
fi

if [[ "${1:-}" != "--skip-build" ]]; then
  # 无需开发者证书即可做一次编译检查；真机安装时再在 Xcode 选择自己的 Team。
  flutter build ios --debug --no-codesign
fi

cat <<'MSG'

iOS 工程准备完成。
下一步：
  1. 打开 ios/Runner.xcworkspace
  2. Runner > Signing & Capabilities 选择你的 Apple Developer Team
  3. 连接 iPhone 后点击 Run

注意：首版生成时必须保持 App 在前台；iOS 后台持续生成尚未实现。
MSG
