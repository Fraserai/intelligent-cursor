import ApplicationServices
import Foundation

/// The accessibility roles semantic targeting matches on.
///
/// Most roles come from the SDK constants. Browser engines also publish
/// web-specific roles such as `AXLink`, `AXWebArea`, and `AXHeading` that have
/// no SDK constant, so every role the app reasons about is named here instead of
/// being split between imported constants and inline literals.
enum AXRole {
    static let application = kAXApplicationRole as String
    static let button = kAXButtonRole as String
    static let cell = kAXCellRole as String
    static let group = kAXGroupRole as String
    static let image = kAXImageRole as String
    static let menuBar = kAXMenuBarRole as String
    static let row = kAXRowRole as String
    static let scrollArea = kAXScrollAreaRole as String
    static let staticText = kAXStaticTextRole as String
    static let textArea = kAXTextAreaRole as String
    static let textField = kAXTextFieldRole as String
    static let window = kAXWindowRole as String

    /// WebKit and Blink roles. Not exported by the macOS SDK.
    static let link = "AXLink"
    static let webArea = "AXWebArea"
    static let heading = "AXHeading"
}
