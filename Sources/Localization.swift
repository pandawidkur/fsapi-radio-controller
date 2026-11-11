import Foundation

/// Localized UI string. Keys are the English texts; Polish lives in pl.lproj/Localizable.strings.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Localized format string, e.g. `L("Saved to preset %d.", slot)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}
