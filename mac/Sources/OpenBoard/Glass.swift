import SwiftUI

/**
 Liquid Glass, in one place.

 macOS 26's material is real API — `glassEffect(_:in:)`, `GlassEffectContainer`,
 `.buttonStyle(.glass)` — but this package deploys to macOS 14, so every use has to be
 behind an availability check with something sensible on the other side. Doing that at
 each call site would mean thirty `if #available` blocks and thirty chances for the
 fallback to drift from the real thing. So it is done once, here.

 ## What gets glass, and what does not

 Apple is explicit, and the first version of this file was not following it:

 > Don't use Liquid Glass in the content layer.

 > Use Liquid Glass effects sparingly. Standard components pick up the appearance
 > automatically. Limit these effects to the most important functional elements.

 The reface began by putting glass on every section card, every button and every show
 card, which is precisely the over-application that warning describes — a settings pane
 scrolling under a title bar *is* the content layer, however nicely it renders. It was
 pulled back to three things:

 - **The popover's keycaps.** A menu floating over another app, and the caps are the
   controls in it.
 - **The blocked row**, tinted, because there orange is the message.
 - **The show cards**, which are the only buttons in the app that are a surface rather
   than a label.

 Everything else went back to a plain material, and ordinary buttons went back to being
 ordinary buttons — the system gives those the new look without being asked.

 **Never glass**: anything carrying a hardware color. The state swatches, the six
 menu-bar dots, the LED preview. Those are the values the pad is emitting, and a
 material that tints and refracts by definition changes what they claim. This app's one
 rule is that the swatch and the key agree.

 ## Not stacked

 Glass on glass is explicitly out: the effect samples what is behind it, so a card
 inside a card produces a muddy double-refraction rather than depth. Where a group of
 shapes sit near each other — the popover's keycaps — they go inside a
 `GlassEffectContainer`, which is what lets them share one sampling pass and blend at
 the edges instead of fighting.
 */
extension View {
    /**
     A grouping container: a section card, a row block, a popover surface.

     `.regular` rather than `.clear` deliberately. Clear is for glass over media, where
     the point is to see the picture through it, and it needs a dimming layer underneath
     to stay legible. Every surface here has text on it.
     */
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(
                .quaternary.opacity(0.3),
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    /**
     A control that reacts to the pointer.

     `interactive()` is what makes the material respond to a press rather than sitting
     there as a texture — the difference between a glass button and a button-shaped
     piece of glass.
     */
    @ViewBuilder
    func glassControl(cornerRadius: CGFloat = 9) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(
                .quaternary.opacity(0.45),
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    /**
     Tinted glass, for a surface that carries meaning.

     Used sparingly and never decoratively: the only tinted surface in the app is the
     blocked row, where orange *is* the message. A tint that means nothing is the
     failure mode Apple warns about, and it is also the failure mode this app has spent
     its whole history avoiding — a color that does not mean anything teaches you to
     stop reading colors.
     */
    @ViewBuilder
    func glassAccent(_ color: Color, cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.tint(color.opacity(0.55)).interactive(),
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(color.opacity(0.2), in: .rect(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// The standard button, as glass. Falls back to the system's bordered style, which
    /// is what it was before.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            buttonStyle(.bordered)
        }
    }
}

extension View {
    /**
     A keycap drawn as glass, in whatever shape it has.

     Only the flat variant — the popover's. The settings window's caps stay moulded
     plastic on purpose: that window is a *picture of the pad*, and a photograph of an
     object should look like the object rather than like the operating system.
     */
    @ViewBuilder
    func glassCap(isFlat: Bool, shape: AnyShape) -> some View {
        if isFlat, #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            self
        }
    }
}

/**
 A group of glass shapes that should behave as one piece of material.

 Without this each shape samples its background independently, so two caps side by side
 have a hard seam between them; inside a container they share the pass and their edges
 blend the way real glass does. It is also the cheaper path — one sample, not N.

 Transparent before macOS 26, where it is simply the layout it wraps.
 */
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
