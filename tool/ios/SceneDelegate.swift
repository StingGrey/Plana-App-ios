import Flutter
import MobileCoreServices
import UIKit
import UniformTypeIdentifiers

class SceneDelegate: FlutterSceneDelegate, UIDropInteractionDelegate {
  private var dropChannel: FlutterMethodChannel?
  private var imageDropInteraction: UIDropInteraction?
  private var cloudFolderBridge: CloudFolderBridge?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    installPlatformBridges()
    // Storyboard 的根控制器可能在 willConnect 返回后才完成挂载。
    DispatchQueue.main.async { [weak self] in
      self?.installPlatformBridges()
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    installPlatformBridges()
  }

  private func installPlatformBridges() {
    installImageDropInteraction()
    installCloudFolderBridge()
  }

  private func installCloudFolderBridge() {
    guard cloudFolderBridge == nil,
          let controller = window?.rootViewController as? FlutterViewController
    else { return }
    cloudFolderBridge = CloudFolderBridge(controller: controller)
  }

  private func installImageDropInteraction() {
    guard imageDropInteraction == nil,
          let controller = window?.rootViewController as? FlutterViewController
    else { return }

    dropChannel = FlutterMethodChannel(
      name: "plana/drop_import",
      binaryMessenger: controller.binaryMessenger
    )
    let interaction = UIDropInteraction(delegate: self)
    controller.view.addInteraction(interaction)
    imageDropInteraction = interaction
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    canHandle session: UIDropSession
  ) -> Bool {
    sessionContainsImage(session)
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidEnter session: UIDropSession
  ) {
    sendDropState("hover")
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidExit session: UIDropSession
  ) {
    sendDropState("idle")
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidEnd session: UIDropSession
  ) {
    sendDropState("idle")
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidUpdate session: UIDropSession
  ) -> UIDropProposal {
    UIDropProposal(operation: sessionContainsImage(session) ? .copy : .forbidden)
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    performDrop session: UIDropSession
  ) {
    guard let provider = session.items
      .map(\.itemProvider)
      .first(where: { imageTypeIdentifier(for: $0) != nil }),
      let typeIdentifier = imageTypeIdentifier(for: provider)
    else {
      sendDropState("idle")
      return
    }

    sendDropState("loading")
    provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) {
      [weak self] data, _ in
      guard let self else { return }
      guard let data, !data.isEmpty else {
        DispatchQueue.main.async { self.sendDropState("idle") }
        return
      }
      let name = self.fileName(for: provider, typeIdentifier: typeIdentifier)
      DispatchQueue.main.async {
        self.dropChannel?.invokeMethod(
          "importImage",
          arguments: [
            "bytes": FlutterStandardTypedData(bytes: data),
            "name": name,
          ]
        )
      }
    }
  }

  private func sessionContainsImage(_ session: UIDropSession) -> Bool {
    session.hasItemsConforming(toTypeIdentifiers: [kUTTypeImage as String])
  }

  private func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
    let preferred = ["public.png", "public.jpeg", "public.heic", "public.webp"]
    if let type = preferred.first(where: {
      provider.hasItemConformingToTypeIdentifier($0)
    }) {
      return type
    }
    return provider.registeredTypeIdentifiers.first(where: {
      UTTypeConformsTo($0 as CFString, kUTTypeImage)
    })
  }

  private func sendDropState(_ state: String) {
    dropChannel?.invokeMethod("dropState", arguments: state)
  }

  private func fileName(
    for provider: NSItemProvider,
    typeIdentifier: String
  ) -> String {
    let ext = UTTypeCopyPreferredTagWithClass(
      typeIdentifier as CFString,
      kUTTagClassFilenameExtension
    )?.takeRetainedValue() as String?
    let suggested = provider.suggestedName?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )

    if let suggested, !suggested.isEmpty {
      if URL(fileURLWithPath: suggested).pathExtension.isEmpty, let ext {
        return "\(suggested).\(ext)"
      }
      return suggested
    }
    return "dropped_image.\(ext ?? "png")"
  }
}

/// iCloud 同步文件夹。用户在系统「文件」里选一个文件夹(通常在 iCloud Drive),
/// 这里存它的书签并代做读写,同步逻辑全在 Dart 侧(lib/features/cloud_sync)。
///
/// **为什么不是 CloudKit**:重签用的描述文件里 iCloud 容器列表是空的,带
/// iCloud entitlement 的包装上去直接起不来。用户选中的文件夹授权不需要任何
/// entitlement,iCloud Drive 负责真正的上传与多设备分发。
///
/// 和 Flutter 文件 API 的分工:所有读写走 NSFileCoordinator,iCloud Drive 才能
/// 感知到变动;读只读已下载的文件,占位文件由 `download` 请求系统后台拉取,
/// 不在这里阻塞等待 —— 离线时协调读会一直挂着,串行队列就全堵死了。
final class CloudFolderBridge: NSObject, UIDocumentPickerDelegate {
  private static let bookmarkKey = "plana.cloudFolder.bookmark"

  private let channel: FlutterMethodChannel
  private weak var controller: UIViewController?
  private let queue = DispatchQueue(label: "plana.cloud_folder", qos: .utility)
  private var folder: URL?
  private var accessing = false
  private var pendingPick: FlutterResult?
  private var activePicker: UIDocumentPickerViewController?

  init(controller: FlutterViewController) {
    channel = FlutterMethodChannel(
      name: "plana/cloud_folder",
      binaryMessenger: controller.binaryMessenger
    )
    self.controller = controller
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "status":
      result(statusPayload())
    case "pick":
      pick(result)
    case "clear":
      UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
      releaseFolder()
      result(nil)
    case "list":
      perform(result) { folder in try Self.list(in: folder) }
    case "read":
      guard let name = args?["name"] as? String else {
        return result(FlutterError(code: "args", message: "缺少文件名", details: nil))
      }
      perform(result) { folder in
        try FlutterStandardTypedData(bytes: Self.read(name, in: folder))
      }
    case "write":
      guard let name = args?["name"] as? String,
            let bytes = args?["bytes"] as? FlutterStandardTypedData
      else {
        return result(FlutterError(code: "args", message: "缺少文件名或内容", details: nil))
      }
      perform(result) { folder in
        try Self.write(name, data: bytes.data, in: folder)
        return nil
      }
    case "download":
      let names = args?["names"] as? [String] ?? []
      perform(result) { folder in
        for name in names {
          if let url = try? Self.child(name, of: folder) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
          }
        }
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 书签

  private func statusPayload() -> [String: Any] {
    guard let folder = resolvedFolder() else {
      let configured = UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
      return ["configured": configured, "available": false]
    }
    let reachable = (try? folder.checkResourceIsReachable()) == true
    return [
      "configured": true,
      "available": reachable,
      "name": folder.lastPathComponent,
    ]
  }

  private func resolvedFolder() -> URL? {
    if let folder { return folder }
    guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
      return nil
    }
    var stale = false
    guard let url = try? URL(
      resolvingBookmarkData: data,
      bookmarkDataIsStale: &stale
    ) else { return nil }
    accessing = url.startAccessingSecurityScopedResource()
    if stale, let fresh = try? url.bookmarkData(
      options: .minimalBookmark,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) {
      UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
    }
    folder = url
    return url
  }

  private func releaseFolder() {
    if accessing { folder?.stopAccessingSecurityScopedResource() }
    folder = nil
    accessing = false
  }

  private func pick(_ result: @escaping FlutterResult) {
    if pendingPick != nil {
      if activePicker?.presentingViewController != nil {
        return result(FlutterError(code: "busy", message: "文件夹选择器已打开", details: nil))
      }
      // 面板下滑关掉时不一定回调 wasCancelled;旧请求不清掉,之后每次点都只会报「已打开」
      finishPick(nil)
    }
    guard let presenter = topPresenter() else {
      return result(FlutterError(code: "no_window", message: "界面还没准备好，请稍后再试", details: nil))
    }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.folder],
      asCopy: false
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pendingPick = result
    activePicker = picker
    presenter.present(picker, animated: true)
    // UIKit 拒绝弹出(上一个弹窗正在收起、界面不在窗口里)时只在控制台打一行警告,
    // 不兜底就是「点了没反应」,Dart 那边的 await 也永远等不到结果。
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.activePicker === picker,
            picker.presentingViewController == nil
      else { return }
      self.finishPick(FlutterError(code: "present", message: "文件夹选择器没能弹出来，请再点一次", details: nil))
    }
  }

  private func topPresenter() -> UIViewController? {
    guard var top = controller, top.viewIfLoaded?.window != nil else { return nil }
    while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
    return top
  }

  private func finishPick(_ value: Any?) {
    let result = pendingPick
    pendingPick = nil
    activePicker = nil
    result?(value)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard pendingPick != nil else { return }
    guard let url = urls.first else { return finishPick(nil) }
    let started = url.startAccessingSecurityScopedResource()
    do {
      let data = try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      releaseFolder()
      UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
      folder = url
      accessing = started
      finishPick(statusPayload())
    } catch {
      if started { url.stopAccessingSecurityScopedResource() }
      finishPick(FlutterError(
        code: "bookmark",
        message: "无法记住这个文件夹：\(error.localizedDescription)",
        details: nil
      ))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishPick(nil)
  }

  // MARK: 文件操作(后台串行队列)

  private func perform(
    _ result: @escaping FlutterResult,
    _ job: @escaping (URL) throws -> Any?
  ) {
    guard let folder = resolvedFolder() else {
      return result(FlutterError(code: "no_folder", message: "还没有选择同步文件夹", details: nil))
    }
    queue.async {
      let reply: Any?
      do {
        reply = try job(folder)
      } catch {
        reply = FlutterError(code: "io", message: error.localizedDescription, details: nil)
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  private static func child(_ name: String, of folder: URL) throws -> URL {
    guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return folder.appendingPathComponent(name, isDirectory: false)
  }

  private static func coordinate(
    _ body: (NSFileCoordinator, inout NSError?) -> Void
  ) throws {
    var error: NSError?
    body(NSFileCoordinator(filePresenter: nil), &error)
    if let error { throw error }
  }

  private static func list(in folder: URL) throws -> [[String: Any]] {
    let keys: [URLResourceKey] = [
      .isRegularFileKey,
      .fileSizeKey,
      .contentModificationDateKey,
      .ubiquitousItemDownloadingStatusKey,
    ]
    var out: [[String: Any]] = []
    var thrown: Error?
    try coordinate { coordinator, error in
      coordinator.coordinate(
        readingItemAt: folder,
        options: .immediatelyAvailableMetadataOnly,
        error: &error
      ) { dir in
        do {
          // 不跳过隐藏文件:iCloud 的未下载占位就是 `.名字.icloud`。
          let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: []
          )
          for url in urls {
            var name = url.lastPathComponent
            var placeholder = false
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
              name = String(name.dropFirst().dropLast(".icloud".count))
              placeholder = true
            } else if name.hasPrefix(".") {
              continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }
            let status = values?.ubiquitousItemDownloadingStatus
            let downloaded = !placeholder && status != .notDownloaded
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            out.append([
              "name": name,
              "size": placeholder ? 0 : (values?.fileSize ?? 0),
              "modified": Int64(modified * 1000),
              "downloaded": downloaded,
            ])
          }
        } catch {
          thrown = error
        }
      }
    }
    if let thrown { throw thrown }
    return out
  }

  private static func read(_ name: String, in folder: URL) throws -> Data {
    let target = try child(name, of: folder)
    var data: Data?
    var thrown: Error?
    try coordinate { coordinator, error in
      coordinator.coordinate(readingItemAt: target, options: [], error: &error) { url in
        do { data = try Data(contentsOf: url) } catch { thrown = error }
      }
    }
    if let thrown { throw thrown }
    guard let data else { throw CocoaError(.fileReadUnknown) }
    return data
  }

  private static func write(_ name: String, data: Data, in folder: URL) throws {
    let target = try child(name, of: folder)
    var thrown: Error?
    try coordinate { coordinator, error in
      coordinator.coordinate(
        writingItemAt: target,
        options: .forReplacing,
        error: &error
      ) { url in
        do { try data.write(to: url, options: .atomic) } catch { thrown = error }
      }
    }
    if let thrown { throw thrown }
  }
}
