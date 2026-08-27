import Flutter
import MobileCoreServices
import UIKit

class SceneDelegate: FlutterSceneDelegate, UIDropInteractionDelegate {
  private var dropChannel: FlutterMethodChannel?
  private var imageDropInteraction: UIDropInteraction?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    installImageDropInteraction()
    // Storyboard 的根控制器可能在 willConnect 返回后才完成挂载。
    DispatchQueue.main.async { [weak self] in
      self?.installImageDropInteraction()
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    installImageDropInteraction()
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
