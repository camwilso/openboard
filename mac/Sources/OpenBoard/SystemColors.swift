import AppKit
import SwiftUI

/**
 The colors macOS already decided.

 Two different system preferences govern this, and they are genuinely separate — a
 machine can have a blue accent and a green highlight at the same time, which this one
 does:

 - **Accent** (`AppleAccentColor`) tints controls and list *selection*. Finder's sidebar
   selection is this color.
 - **Highlight** (`AppleHighlightColor`) is what selected *text* looks like, and what a
   row tinted "the way the user asked for" should follow.

 ## Why this file exists at all

 SwiftUI resolves `Color.accentColor` from an `AccentColor` asset in the bundle's asset
 catalog. This app is built with SwiftPM and no Xcode, so there is no `actool` and no
 asset catalog — so that lookup finds nothing and falls back to a **fixed blue**,
 regardless of what the user chose. Every tint in the app was that fallback.

 `NSColor.controlAccentColor` and friends read the live preference instead, so they
 follow the system including a mid-session change.
 */
enum SystemColors {
    /// What macOS tints controls and list selection with.
    static var accent: Color { Color(nsColor: .controlAccentColor) }

    /**
     The user's chosen highlight, at full strength.

     Read from `AppleHighlightColor` rather than taken from `selectedTextBackgroundColor`,
     which is the same choice already softened for use *behind text* — on this machine
     the preference is `#04402B` and the softened form is `#B5C6C0`, which is nearly
     grey and useless as a row fill.

     AppKit exposes no "highlight at full strength" color, so the preference is parsed
     directly. It is three floats and a name: `0.023529 0.250980 0.168627 Other`.
     Anything unparseable falls back to the standard selection fill, so a missing or
     reformatted preference costs the color and never the window.
     */
    static var highlight: Color {
        guard let raw = UserDefaults.standard.string(forKey: "AppleHighlightColor") else {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        let parts = raw.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        return Color(.sRGB, red: parts[0], green: parts[1], blue: parts[2])
    }

    /// True when the highlight has been changed from the system default, so the app can
    /// prefer it over the accent without overriding people who never touched it.
    static var hasCustomHighlight: Bool {
        UserDefaults.standard.string(forKey: "AppleHighlightColor") != nil
    }

    /**
     A row under the pointer.

     Derived from the same colour as selection, at low opacity: a full-strength
     highlight reads as *selected*, and nothing in the popover is — it is a pointer
     position, not a state.

     Deliberately not `selectedTextBackgroundColor`, which is the user's choice already
     softened for use behind text. Over a light surface that lands somewhere near grey
     and stops looking like their colour at all, which defeats the point of following
     the setting.
     */
    static var hover: Color { selectedRow.opacity(0.22) }

    /**
     What a selected row is filled with.

     macOS convention is the *accent*, which is what Finder's sidebar uses. This prefers
     the **highlight** when one has been explicitly chosen, because someone who set a
     custom highlight has said what color they want selection to be — and on a machine
     where the two differ, following the accent looks like the app ignoring them.

     Untouched machines fall through to the accent and behave exactly like every other
     Mac app.
     */
    static var selectedRow: Color {
        hasCustomHighlight ? highlight : Color(nsColor: .selectedContentBackgroundColor)
    }

    /// The standard selected-row fill, which already follows the accent and adapts to
    /// whether the window is key.
    static var selection: Color { Color(nsColor: .selectedContentBackgroundColor) }
}
