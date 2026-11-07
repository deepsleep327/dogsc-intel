import AppKit
import AVFoundation
import ScreenCaptureKit

/// Swift 6.1 + macOS 15 SDK compatibility shims.
///
/// The upstream DogSC sources are built against the macOS 26 SDK (Xcode 26),
/// where `SCShareableContent`, `AVAssetTrack` and related AVFoundation types
/// carry complete `Sendable` annotations. The macOS 15 SDK that ships with
/// Command Line Tools for Xcode 16 marks several of those types as
/// non-sendable, which makes `await`-ing them from a `@MainActor` context a
/// compile error under Swift 6 strict concurrency.
///
/// The helpers below box the results of those calls in explicitly
/// `@unchecked Sendable` wrappers so the values can cross isolation domains,
/// preserving the exact upstream threading behaviour (the boxed types are only
/// ever handed back to the caller that requested them).
///
/// This file compiles away entirely when building with the macOS 26 SDK: the
/// call sites use these helpers only when `compiler(>=6.2)` is false.

/// A sendable box around a single decoded `NSImage`.
struct DogSCImageBox: @unchecked Sendable {
    let image: NSImage?
}

/// Sendable boxes for non-Sendable SDK results in Swift 6.1 / macOS 15 SDK.
enum DogSCSDKCompatibility {
    struct ShareableContentBox: @unchecked Sendable {
        let content: SCShareableContent
    }

    struct AssetTrackList: @unchecked Sendable {
        let tracks: [AVAssetTrack]
    }

    /// `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)`
    /// returns a non-sendable `SCShareableContent` under the macOS 15 SDK.
    /// Boxing keeps the await legal from any isolation domain.
    static func shareableContent(
        excludingDesktopWindows: Bool,
        onScreenWindowsOnly: Bool
    ) async throws -> ShareableContentBox {
        ShareableContentBox(
            content: try await SCShareableContent.excludingDesktopWindows(
                excludingDesktopWindows,
                onScreenWindowsOnly: onScreenWindowsOnly
            )
        )
    }

    /// `AVAsset.loadTracks(withMediaType:)` returns `[AVAssetTrack]`, which is
    /// non-sendable under the macOS 15 SDK.
    static func loadTracks(
        from asset: AVAsset,
        mediaType: AVMediaType
    ) async throws -> AssetTrackList {
        AssetTrackList(tracks: try await asset.loadTracks(withMediaType: mediaType))
    }
}
