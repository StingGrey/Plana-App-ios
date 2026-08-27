import Flutter
import MobileCoreServices
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, UIDropInteractionDelegate {
  private var dropChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )

    if let controller = window?.rootViewController as? FlutterViewController {
      dropChannel = FlutterMethodChannel(
        name: "plana/drop_import",
        binaryMessenger: controller.binaryMessenger
      )
      controller.view.addInteraction(UIDropInteraction(delegate: self))
    }
    return launched
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    canHandle session: UIDropSession
  ) -> Bool {
    session.hasItemsConforming(toTypeIdentifiers: [kUTTypeImage as String])
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidUpdate session: UIDropSession
  ) -> UIDropProposal {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    performDrop session: UIDropSession
  ) {
    guard let provider = session.items
      .map(\.itemProvider)
      .first(where: { $0.hasItemConformingToTypeIdentifier(kUTTypeImage as String) })
    else { return }

    guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
      UTTypeConformsTo($0 as CFString, kUTTypeImage)
    }) else { return }

    provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) {
      [weak self] data, _ in
      guard let self, let data, !data.isEmpty else { return }
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
