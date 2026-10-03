> 本文件是 [视觉设计评审主报告](visual-design-review.md) 的配套参考资料：Apple 官方 HIG / SwiftUI 文档 / macOS 27 SDK 的逐条引用与可用性注解。

# Apple macOS Design Language — Citation-Backed Reference for a SwiftUI macOS UI Review

**Prepared for:** UI review of a SwiftUI macOS app with deployment target **macOS 14.0**, built with Xcode 27.0 / Swift 6.4.

**Host facts (verified on this machine):** `sw_vers` → ProductVersion **27.0**, BuildVersion **26A428**; `xcrun --show-sdk-version` → **27.0** (`MacOSX27.0.sdk`). SwiftUI / SwiftUICore / AppKit `.swiftinterface` files and AppKit headers were read directly from the SDK.

**Evidence tags used throughout:**
- `[HIG]` Apple Human Interface Guidelines page (URL given)
- `[DOC]` Apple developer documentation symbol/article page (URL given)
- `[SDK]` availability annotation read from the macOS 27.0 SDK (`.swiftinterface` / AppKit `.h`)
- `[WWDC]` WWDC session transcript (URL given)
- `[NEWS]` Apple Newsroom / apple.com marketing page
- `[MEASURED]` value measured on this host by running AppKit code; method stated inline

> **Two eras.** Liquid Glass shipped with **macOS 26 "Tahoe"** (WWDC25). The current release is **macOS 27 "Golden Gate"** (WWDC26), which *refines* rather than replaces it. Both matter for a review run on a macOS 27 host.

---

## 0. Version landscape and naming

| Fact | Source |
|---|---|
| The new design "extends across iOS 26, iPadOS 26, **macOS Tahoe 26**, watchOS 26, and tvOS 26" | [NEWS](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/) |
| "It's crafted with a new material called Liquid Glass." | [NEWS](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/) |
| macOS 26 press release title: "**macOS Tahoe 26** makes the Mac more capable, productive, and intelligent than ever" | [NEWS](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/) |
| Apple's current macOS page titles itself "**OS - macOS 27 Golden Gate**" | [NEWS](https://www.apple.com/macos/) |
| macOS 27 headline design claim: "More refined design with **enhanced Liquid Glass**, ensuring exceptional readability and greater consistency across apps." | [NEWS](https://www.apple.com/macos/) |
| macOS 27 design refinements: "Updates to Liquid Glass ensure exceptional readability with **more uniform refraction and improved contrast. Uniform toolbars, edge-to-edge sidebars, and updated window shapes and menu bar icons** deliver a more refined design. And a new slider lets you easily customize how Liquid Glass looks, **from ultraclear to fully tinted**." | [NEWS](https://www.apple.com/macos/) |
| macOS 27 System Settings: "An all-new design makes **parental controls in System Settings** even easier to use." | [NEWS](https://www.apple.com/macos/) |
| SwiftUI changes are published under dated headings ("September 2026", "June 2026", "June 2025", "June 2024") — confirming the macOS 27 / 26 / 15 / 14 split | [DOC](https://developer.apple.com/documentation/updates/swiftui) |

**Review implication:** every Liquid Glass API is **macOS 26.0+**. With a macOS 14 deployment target, all of them must sit behind `if #available(macOS 26.0, *)`. Nothing in the Liquid Glass surface back-deploys.

---

## 1. Liquid Glass

### 1.1 What it is

| Claim | Source |
|---|---|
| "Interfaces across Apple platforms feature a new dynamic **material** called Liquid Glass, which combines the optical properties of glass with a sense of fluidity. … **This material forms a distinct functional layer for controls and navigation elements.** It … adapts in response to a variety of factors to help bring focus to the underlying content." | [DOC](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) |
| "**Standard components from SwiftUI, UIKit, and AppKit** like controls and navigation elements **pick up the appearance and behavior of this material automatically.**" | [DOC](https://developer.apple.com/documentation/technologyoverviews/liquid-glass) |
| "rather than trying to simply recreate a material from the physical world, Liquid Glass is a new digital **meta-material** that dynamically bends and shapes light." | [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| "The primary way Liquid Glass visually defines itself is through something called **Lensing**." / "Where as previous materials scattered light, this new set of materials dynamically **bends, shapes, and concentrates light in real time**." | [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| "Instead of fading, Liquid Glass objects materialize in and out by gradually modulating the light bending and lensing…" | [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| "Glass controls nest perfectly into the rounded corners of windows, maintaining **concentricity** throughout the UI." | [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| "when a window loses focus on the Mac or iPad, Liquid Glass shifts its appearance and **visually recedes** to guide attention." | [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| Automatic accessibility behaviour: "**Reduced Transparency**, makes Liquid Glass frostier and obscures more of the content behind it. **Increased contrast**, makes elements predominantly black or white and highlights them with a contrasting border and **Reduced Motion** decreases the intensity of some effects and disables any elastic properties… **These are available automatically whenever you use the new material.**" | [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| Exactly two material types exist: "**two types of materials: Liquid Glass, and standard materials**"; standard materials "help with visual differentiation **within the content layer**." | [HIG materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| "**Liquid Glass forms a distinct functional layer** for controls and navigation elements — like tab bars and sidebars — that **floats above the content layer**"; content can "scroll and peek through from beneath these elements". | [HIG materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| Two variants: "**regular**" and "**clear**"; "They **should never be mixed**." | [HIG materials](https://developer.apple.com/design/human-interface-guidelines/materials) / [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| Regular: "blurs and adjusts the luminosity of background content to maintain legibility" — "Use the regular variant when background content might create legibility issues, or when components have a significant amount of text, such as **alerts, sidebars, or popovers**." | [HIG materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| Clear: "is highly translucent, which is ideal for prioritizing the visibility of the underlying content"; "Only use clear Liquid Glass for components that appear over **visually rich backgrounds**" — "such as photos and videos". | [HIG materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| Dimming (numeric): "If the underlying content is bright, consider adding a dark dimming layer of **35% opacity**." | [HIG materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| Three conditions for Clear (all required): "First, the element you're applying it to is over media-rich content. Second, your content layer won't be negatively affected by introducing a dimming layer. And lastly, the content sitting above it is bold and bright." | [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| Light/dark flipping split by size: "Small elements like navbars and tabbars, constantly adapt their appearance… They also flip from light to dark… **Bigger elements, like menus or sidebars also adapt based on context, but they don't flip from light to dark.** Their surface area is too big and transitions like these would be distracting." | [WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/) |
| macOS 27: the 2027 look arrives "without having to change a single line of code!"; the material "automatically responds to the new Liquid Glass slider to adjust its tint"; custom glass can be marked "interactive" on macOS and is "optimized to work great with the mouse pointer". | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |

### 1.2 SwiftUI API surface — exact availability annotations

Read from `SwiftUICore.framework/…/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface` and `SwiftUI.framework/…/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface` inside `MacOSX27.0.sdk` `[SDK]`, cross-checked against the doc pages `[DOC]`.

| API | macOS availability | Notes | Source |
|---|---|---|---|
| `View.glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View` | **macOS 26.0** | `@available(visionOS, unavailable)`. "SwiftUI anchors the Liquid Glass to a view's bounds." | [DOC](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) / [SDK] |
| `Glass` (struct) | **macOS 26.0** | Members: `.regular`, `.clear`, `.identity`, `func interactive(Bool) -> Glass`, `func tint(Color?) -> Glass` | [DOC](https://developer.apple.com/documentation/swiftui/glass) / [SDK] |
| `DefaultGlassEffectShape` | **macOS 26.0** | Default shape is a `Capsule` | [DOC](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) / [SDK] |
| `GlassEffectContainer<Content>` | **macOS 26.0** | `init(spacing: CGFloat?, content: () -> Content)`. "improving rendering performance and allowing the effects to interact with and morph into one another." | [DOC](https://developer.apple.com/documentation/swiftui/glasseffectcontainer) / [SDK] |
| `View.glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID)` | **macOS 26.0** | Drives morph transitions | [SDK] |
| `View.glassEffectUnion(id:namespace:)` | **macOS 26.0** | Merges separate views into one glass shape | [SDK] |
| `View.glassEffectTransition(_:)` / `GlassEffectTransition` | **macOS 26.0** | `.identity`, `.materialize`, `.matchedGeometry` | [DOC](https://developer.apple.com/documentation/swiftui/glasseffecttransition) / [SDK] |
| `PrimitiveButtonStyle.glass` → `GlassButtonStyle` | **macOS 26.0** | `@available(visionOS, unavailable)`. Usage: `buttonStyle(.glass)` | [DOC](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass) / [SDK] |
| `PrimitiveButtonStyle.glassProminent` → `GlassProminentButtonStyle` | **macOS 26.0** | "similar to the `borderedProminent` style" | [DOC](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glassprominent) / [SDK] |
| `View.backgroundExtensionEffect()` | **macOS 26.0** | "The view will be duplicated into **mirrored copies** … a **blur** effect will be applied on top"; "Apply this modifier with **discretion**… only a single instance of background content" | [DOC](https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()) / [SDK] |
| `View.backgroundExtensionEffect(isEnabled:)` | **macOS 26.0** | Second overload | [SDK] |
| `View.scrollEdgeEffectStyle(_:for:)` | **macOS 26.0** | `@available(visionOS, unavailable)` | [DOC](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)) / [SDK] |
| `ScrollEdgeEffectStyle` — `.soft`, `.hard` | **macOS 26.0** | `.hard` = "more opaque, clearly defined linear boundary"; `.soft` = "subtle blurred transition"; `nil` = none | [DOC](https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle) / [SDK] |
| `View.scrollEdgeEffectHidden(_:for:)` | **macOS 26.0** | | [DOC](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffecthidden(_:for:)) / [SDK] |
| `ConcentricRectangle` | **macOS 26.0** | "A rounded corner … is *concentric* relative to the container shape's adjacent corner when the corner's radius shares a common center with the containing shape's rounded corner radius." | [DOC](https://developer.apple.com/documentation/swiftui/concentricrectangle) / [SDK] |
| `View.containerShape(_ shape: some RoundedRectangularShape)` | **macOS 26.0** | The older overload taking `ContainerRelativeShape` predates it (macOS 11+). `RoundedRectangularShape` / `RoundedRectangularShapeCorners` are macOS 26.0 | [DOC](https://developer.apple.com/documentation/swiftui/view/containershape(_:)) / [SDK] |
| `View.containerCornerOffset(_ edges: Edge.Set, sizeToFit: Bool = false)` | **macOS 26.0** | "adapt to avoid the **container view's corner insets**… may include pieces of system UI as well as the corner radii for windows and presentations" | [DOC](https://developer.apple.com/documentation/swiftui/view/containercorneroffset(_:sizetofit:)) / [SDK] |
| `View.buttonSizing(_ sizing: ButtonSizing)` / `ButtonSizing` | **macOS 26.0** | "you can make certain styles of `Button`, `Picker`, `ControlGroup`, and `Toggle` **flexible**"; "may want to do [this] if the button is placed in a narrow context, like the sidebar of a welcome window" | [DOC](https://developer.apple.com/documentation/swiftui/view/buttonsizing(_:)) / [SDK] |
| `View.controlSize<T>(_ range: T)` (`T: RangeExpression, T.Bound == ControlSize`) | **macOS 26.0** | New range overload; `ControlSize` gained `Comparable` | [SDK] |
| `View.labelReservedIconWidth(_ value: CGFloat)` | **macOS 26.0** | "set the value that should be used for the **reserved icon width** in labels." | [DOC](https://developer.apple.com/documentation/swiftui/view/labelreservediconwidth(_:)) / [SDK] |
| `ToolbarContent.sharedBackgroundVisibility(_ visibility: Visibility)` | **iOS 26.0 / macOS 26.0** | "Hiding the effect will cause the item to be placed in its own grouping." | [DOC](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:)) / [SDK] |
| `Slider` `sliderThumbVisibility(_:)` | **macOS 26.0** | | [SDK] |
| `View.lineHeight(_:)` | **macOS 26.0** | | [SDK] |
| `SearchToolbarBehavior` / `View.searchToolbarBehavior(_:)` | **macOS 26.0** | Opt in to collapsing search into a toolbar button | [SDK] |
| `NavigationSplitViewStyle.prominentDetail` | macOS 13.0 (not new in 26) | Doc availability: iOS 16.0 / macOS 13.0 | [DOC](https://developer.apple.com/documentation/swiftui/navigationsplitviewstyle/prominentdetail) |

**SwiftUI snippets straight from Apple's session** — [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/):

```swift
Label("Desert", systemImage: "sun.max.fill").padding().glassEffect()                    // default capsule
Label("Desert", systemImage: "sun.max.fill").padding().glassEffect(in: .rect(cornerRadius: 16))
Label("Desert", systemImage: "sun.max.fill").padding().glassEffect(.regular.tint(.green))
Label("Desert", systemImage: "sun.max.fill").padding().glassEffect(.regular.interactive())
Button("Get Started") { }.buttonStyle(.glassProminent)
Button("Learn More")  { }.buttonStyle(.glass)
```

```swift
@Namespace var namespace
GlassEffectContainer {                       // "essential for visual correctness"
  VStack {
    if isExpanded {
      VStack(spacing: 16) {
        ForEach(badges) { badge in
          BadgeLabel(badge: badge).glassEffect().glassEffectID(badge.id, in: namespace)
        }
      }
    }
    BadgeToggle().buttonStyle(.glass).glassEffectID("badgeToggle", in: namespace)
  }
}
```

Why the container is mandatory: "glass can not sample other glass, so having nearby glass elements in different containers will result in inconsistent behavior." — [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/)

### 1.3 APIs that are macOS 14 / 15, **not** 26 — do not confuse these with Liquid Glass

| API | Availability | Source |
|---|---|---|
| `View.toolbar(removing defaultItemKind:)` | **macOS 14.0** (iOS 17, tvOS 17, watchOS 10) | [DOC](https://developer.apple.com/documentation/swiftui/view/toolbar(removing:)) |
| `ToolbarDefaultItemKind` | **macOS 14.0** | [SDK] |
| `ContainerBackgroundPlacement` (`.navigation`, `.navigationSplitView`, `.tabView`, `.widget`, …) | **macOS 14.0** | [DOC](https://developer.apple.com/documentation/swiftui/containerbackgroundplacement) |
| `SettingsLink` | **macOS 14.0 only** (iOS/tvOS/watchOS/visionOS unavailable) | [DOC](https://developer.apple.com/documentation/swiftui/settingslink) / [SDK] |
| `ContentUnavailableView` | **macOS 14.0** | [SDK] |
| `ControlSize.extraLarge` | **macOS 14.0** (iOS 17, tvOS 17, visionOS 1, watchOS 10) | [SDK] |
| `View.toolbarBackgroundVisibility(_:for:)` | **macOS 15.0** (iOS 18) | [DOC](https://developer.apple.com/documentation/swiftui/view/toolbarbackgroundvisibility(_:for:)) |
| `View.toolbarVisibility(_:for:)` | **macOS 15.0** (iOS 18) | [DOC](https://developer.apple.com/documentation/swiftui/view/toolbarvisibility(_:for:)) |
| `TabViewStyle.sidebarAdaptable` / `SidebarAdaptableTabViewStyle` | **macOS 15.0** (iOS 18, tvOS 18, visionOS 2; watchOS unavailable) | [SDK] |
| `NavigationSplitView` | **macOS 13.0** | [DOC](https://developer.apple.com/documentation/swiftui/navigationsplitview) |
| `Material` and all its statics | **macOS 12.0** | [DOC](https://developer.apple.com/documentation/swiftui/material) |
| `Settings` scene | **macOS 11.0** | [DOC](https://developer.apple.com/documentation/swiftui/settings) |

### 1.4 macOS 27 ("Golden Gate") additions to the same surface

| API | Availability | What it does | Source |
|---|---|---|---|
| `View.textInputBorderShape(_ shape: TextInputBorderShape)` | **macOS 27.0** | "customize the border shape of `TextField` and other text input controls" | [DOC](https://developer.apple.com/documentation/swiftui/view/textinputbordershape(_:)) |
| `BorderedTextFieldStyle` (`.textFieldStyle(.bordered)`) | **macOS 27.0** | "The shape of the border is determined by the `textInputBorderShape(_:)` modifier." | [DOC](https://developer.apple.com/documentation/swiftui/borderedtextfieldstyle) |
| `ContentBuilder` | macOS 27 | "multiple different builder types have been unified under a single builder: ContentBuilder!"; "an evolution of the existing ViewBuilder"; usable "with any minimum deployment target"; fixes "The compiler is unable to type-check this expression in reasonable time" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `ToolbarOverflowMenu` | macOS 27 | "always place these buttons in the overflow menu by grouping them in the new ToolbarOverflowMenu container" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `ToolbarContent.visibilityPriority(_:)` | macOS 27 | "`.visibilityPriority(.high)` … setting the priority to high. Now, the Undo and Redo buttons become visible!" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `ToolbarItemPlacement.topBarPinnedTrailing` | macOS 27 | makes an item "always visible in the trailing position" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `View.toolbarMinimizationBehavior(_:for:)` | macOS 27 | "`.toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)`" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `DynamicViewContent.reorderable()` + `View.reorderContainer(for:in:)` | macOS 26+ (dragContainer is 27 on iOS/iPadOS/visionOS) | "works with any container, not just List!" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/), [WWDC26 271](https://developer.apple.com/videos/play/wwdc2026/271/) |
| `View.swipeActions(edge:allowsFullSwipe:content:onPresentationChanged:)` + `View.swipeActionsContainer()` | macOS 27 | "now, SwiftUI supports swipe actions on any view, not just List!" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `Tab(role: .prominent)` / `TabRole.prominent` | macOS 27 | tab sits on "the bottom trailing edge of the screen" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `.alert(_:item:)` / `.confirmationDialog(_:item:)` | macOS 27 | "confirmation dialogs support the same item-binding pattern that sheets use." / "And this also works with alert!" | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `ReadableDocument` / `WritableDocument` / `DocumentReader` / `DocumentWriter` | macOS 27 | Document protocols for URL-based documents | [WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) |
| `TabsPickerStyle` (`.pickerStyle(.tabs)`) | **macOS 27.0** | New picker style | [SDK] |
| AppKit `NSTextSelectionManager` | **macOS 27.0** | "It's a new API in macOS 27 … brings classic macOS text selection behaviors to any view" | [WWDC26 289](https://developer.apple.com/videos/play/wwdc2026/289/) |
| AppKit `NSViewCornerConfiguration` / `NSViewCornerRadius` with `.containerConcentric`, `.uniformCorners` | macOS 27 | Corner configuration with a minimum radius | [WWDC26 289](https://developer.apple.com/videos/play/wwdc2026/289/) |
| `NSGlassEffectView.effectIsInteractive` | **macOS 27.0** | "Enables interactive glass behavior, which adds a visual response to user interactions." | [SDK header](https://developer.apple.com/documentation/appkit/nsglasseffectview) |

**Note (verified absence):** no `glassEffect` API, no extra-large control size, and **no numeric corner-radius/opacity values for Liquid Glass** appear in any WWDC26 transcript.

### 1.5 AppKit equivalents (relevant if the app mixes AppKit)

| API | Availability | Source |
|---|---|---|
| `NSGlassEffectView` — `contentView`, `cornerRadius`, `tintColor`, `style` | **macOS 26.0** | [DOC](https://developer.apple.com/documentation/appkit/nsglasseffectview) / [SDK header `NSGlassEffectView.h`] |
| `NSGlassEffectViewStyle` = `NSGlassEffectViewStyleRegular` \| `NSGlassEffectViewStyleClear` | **macOS 26.0** | [SDK header] |
| `NSGlassEffectContainerView` — `contentView`, `spacing` | **macOS 26.0** | [SDK header] |
| `NSBezelStyleGlass` (`= 16`) | **macOS 26.0** | [SDK header `NSButtonCell.h`] |
| `NSToolbarItem.backgroundTintColor` | **macOS 26.0** | [SDK header `NSToolbarItem.h`] |
| `NSToolbarItem.badge` / `NSItemBadge` (`badgeWithCount:`, `badgeWithText:`, `indicatorBadge`) | **macOS 26.0** | [SDK header `NSItemBadge.h`] |
| `NSView.prefersCompactControlSizeMetrics` | **macOS 26.0** | [SDK header `NSView.h`] |
| `NSScrollEdgeEffectStyle` (`automaticStyle`, `softStyle`, `hardStyle`) | **macOS 26.1** | [SDK header `NSScrollEdgeEffect.h`] |
| `NSBackgroundExtensionView` | macOS 26 | [SDK header `NSBackgroundExtensionView.h`] |
| `NSSplitViewItemAccessoryViewController` | macOS 26 | [WWDC25 310](https://developer.apple.com/videos/play/wwdc2025/310/) |
| `NSVisualEffectView` | long-standing | [DOC](https://developer.apple.com/documentation/appkit/nsvisualeffectview) — but see §8: it must be **removed from sidebars** |

Apple's AppKit rationale for the container: "glass can't directly sample other glass, so the visual results in this case will not be consistent" and the container "improves the performance of the glass effect, since it only needs **one sampling pass** for the entire group" — [WWDC25 310](https://developer.apple.com/videos/play/wwdc2025/310/).

