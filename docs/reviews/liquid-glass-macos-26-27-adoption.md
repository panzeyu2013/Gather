# Liquid Glass — macOS 26 / macOS 27 Opt-In Adoption Report

**Scope.** Every symbol and quotation below is traceable to an Apple page fetched for this report (URLs in §5). `LC_BUILD_VERSION`/SDK is what flips an app from the legacy appearance to Liquid Glass; that part is done. This report covers only the **opt-in** work Apple asks for on top of automatic adoption.

**Deployment-target warning.** This app deploys to macOS 14. Every API marked macOS 26.0 / 26.1 / 27.0 needs `if #available(...)` gating or a raised deployment target. The automatic restyle is **SDK-driven, not `#available`-driven**, so it does not need gating.

---

## 1. What changes automatically vs what you must opt into

### (a) Free — AppKit/SwiftUI restyle these for you once you link the current SDK

> "If your app uses standard components from SwiftUI, UIKit, or AppKit, your interface picks up the latest look and feel on the latest platform releases… In system frameworks, standard components like bars, sheets, popovers, and controls automatically adopt this material." — *Adopting Liquid Glass*

| Surface in this app | What you get for free |
|---|---|
| `NavigationSplitView` + sidebar `List` | Sidebar floats in the Liquid Glass functional layer; "Liquid Glass appears more opaque in larger elements like sidebars to preserve legibility over complex backgrounds" (HIG Color) |
| `ToolbarItem` / `NSToolbar` | Toolbar takes a Liquid Glass appearance; "window titles can display inline with controls, and toolbar items don't include a bezel" (HIG Toolbars, macOS) |
| Buttons, Toggles, Sliders, Steppers, Pickers, TextFields | Refreshed shape/size; knobs become glass during interaction; "many controls adopt rounder forms" — **only if you do not hard-code layout metrics** |
| Lists, tables, forms | Larger row height and padding; sections get an increased corner radius |
| Section headers | Switch to **title-style capitalization** — "section headers no longer render entirely in capital letters regardless of the capitalization you provide" |
| Windows / sheets / popovers | "Windows adopt rounder corners"; sheets get an increased corner radius; iOS half-sheets are inset and become more opaque at full height |
| Scrollable content under system bars | Scroll edge effect is applied by default to system bars |
| Menus | Adopt Liquid Glass; standard selectors get icons automatically (Cut/Copy/Paste) |
| Action sheets / confirmation dialogs | Originate from the source control |

### (b) Opt-in — you must write code

1. **Custom glass surfaces** — `glassEffect(_:in:)`, `Glass`, `GlassEffectContainer`.
2. **Custom glass buttons** — `.buttonStyle(.glass)`, `.glassProminent`, `.glass(_:)`.
3. **Custom glass animation** — `glassEffectID(_:in:)`, `glassEffectTransition(_:)`, `glassEffectUnion(id:namespace:)`.
4. **Edge-to-edge detail content under sidebar/inspector** — `backgroundExtensionEffect()`.
5. **Custom bars / custom legibility tuning** — `safeAreaBar(edge:alignment:spacing:content:)`, `scrollEdgeEffectStyle(_:for:)`, `scrollEdgeEffectHidden(_:for:)`.
6. **Toolbar grouping & priority** — `ToolbarSpacer`, `SpacerSizing`, `visibilityPriority(_:)`, `.toolbar(id:)` customization.
7. **Toolbar minimization (macOS 27 only)** — `toolbarMinimizationBehavior(_:for:)`.
8. **Concentric corners** — `ConcentricRectangle`, `Shape.rect(corners:isUniform:)`, `containerShape(_:)`.
9. **AppKit code paths** — `NSGlassEffectView`, `NSGlassEffectContainerView`, `NSBackgroundExtensionView`, `NSButton.BezelStyle.glass`, `NSToolbarItem.Style.prominent` + `backgroundTintColor`, and (macOS 27) `NSGlassEffectView.effectIsInteractive`.

### (c) Audits Apple explicitly demands (work you must *remove*, not add)

- **"Reduce your use of custom backgrounds in controls and navigation elements."** Drop custom backgrounds/appearance overrides on `NavigationSplitView`, the sidebar, the toolbar, sheets and popovers — they "might overlay or interfere with Liquid Glass or other effects that the system provides, such as the scroll edge effect."
- **"Audit the backgrounds of sheets and popovers"** — remove visual-effect views added to popover content.
- **"Audit toolbar customizations"** — fixed spacers and custom items can go inconsistent with system behavior.
- **"Check how you hide toolbar items"** — hide the *item*, not the view inside it, or you get an empty glass pill.
- **Accessibility label on every icon** toolbar item.
- **Test with Reduce Transparency / Reduce Motion / Increase Contrast** and with the user's preferred Liquid Glass look.
- **Performance:** "Limit the use of Liquid Glass effects onscreen at the same time" and combine effects with a container.

### (d) Opt-outs worth knowing (in case something regresses)

| API | Availability | Effect |
|---|---|---|
| `UIDesignRequiresCompatibility` (Info.plist) | macOS 26.0+ | Ships the app with the previous (pre-Liquid-Glass) appearance |
| `NSView.prefersCompactControlSizeMetrics` | macOS 26.0+ | Uses macOS 15-and-earlier control metrics |
| `Glass.identity` | macOS 26.0+ | No-op glass — lets you keep one view path and disable glass conditionally |
| `scrollEdgeEffectHidden(_:for:)` | macOS 26.0+ | Removes the scroll edge effect for chosen edges |

---

## 2. Exact SwiftUI API surface (macOS 26.0+), with signatures and availability

### 2.1 Core glass material

**`glassEffect(_:in:)` — macOS 26.0+** — Applies the Liquid Glass material within a shape behind the view, plus foreground effects over it.
```swift
nonisolated func glassEffect(_ glass: Glass = .regular,
                             in shape: some Shape = DefaultGlassEffectShape()) -> some View

Text("Hello, World!").font(.title).padding()
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
```
Notes: default variant is `.regular`, default shape is an implicit `Capsule`. SwiftUI anchors the glass to the view's **bounds** (padding included). Apply it **after** other appearance modifiers, and use it with a `GlassEffectContainer`.

**`Glass` — struct, macOS 26.0+** — Configuration value for the material.
```swift
struct Glass
static var regular: Glass { get }      // default; blurs + adjusts luminosity
static var clear: Glass { get }        // highly translucent; media backgrounds only
static var identity: Glass { get }     // no effect applied
func tint(_ color: Color?) -> Glass
func interactive(_ isEnabled: Bool = true) -> Glass

Text("Hello").padding()
    .glassEffect(.regular.tint(.orange).interactive())
```
- `.clear` — "When using clear glass, ensure content remains legible by adding a dimming layer or other treatment beneath the glass." Apple's own example pairs it with `.background(.black.opacity(0.3))`.
- `.interactive()` — "applies the same responsive and fluid reactions that `.glass` provides to standard buttons."

### 2.2 Containers, identity, transitions

**`GlassEffectContainer` — macOS 26.0+** — Combines multiple Liquid Glass shapes into one shape so they can blend and morph; required for good rendering performance.
```swift
@MainActor @preconcurrency struct GlassEffectContainer<Content> where Content : View
init(spacing: CGFloat? = nil, @ContentBuilder content: () -> Content)

GlassEffectContainer(spacing: 40) {
    HStack(spacing: 40) {
        Image(systemName: "scribble.variable").frame(width: 80, height: 80).glassEffect()
        Image(systemName: "eraser.fill").frame(width: 80, height: 80).glassEffect()
    }
}
```
**Why merging matters:** "SwiftUI renders the effects together, improving rendering performance and allowing the effects to interact with and morph into one another." Set container `spacing` **≥** the inner stack's spacing or shapes blend at rest. "Creating too many Liquid Glass effect containers and applying too many effects to views outside of containers can degrade performance."

**`glassEffectID(_:in:)` — macOS 26.0+** — Names an effect so SwiftUI can morph shapes to/from each other across a hierarchy change.
```swift
nonisolated func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View

@Namespace private var namespace
Image(systemName: "eraser.fill").frame(width: 80, height: 80)
    .glassEffect().glassEffectID("eraser", in: namespace)
```

**`GlassEffectTransition` — macOS 26.0+** — Describes what happens when an effect is added/removed.
```swift
struct GlassEffectTransition
static var matchedGeometry: GlassEffectTransition   // default inside container spacing
static var materialize: GlassEffectTransition       // fade material in/out, no geometry match

.glassEffectTransition(.materialize)
```
Apple's rule: use `matchedGeometry` when the appearing/disappearing effect is **within** the container's spacing; use `materialize` when it is **farther** than that spacing. Prefer only these two.

**`glassEffectUnion(id:namespace:)` — macOS 26.0+** — Makes several views contribute to a *single* glass shape even at rest (useful outside layout containers).
```swift
@MainActor @preconcurrency func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
```

### 2.3 Buttons

**`PrimitiveButtonStyle.glass` / `.glassProminent` / `.glass(_:)` — macOS 26.0+**
```swift
@export(implementation) nonisolated static var glass: GlassButtonStyle { get }
@MainActor @export(implementation) @preconcurrency static var glassProminent: GlassProminentButtonStyle { get }
nonisolated static func glass(_ glass: Glass) -> Self

Button("Button") {}.buttonStyle(.glass)
Button("Button") {}.buttonStyle(.glassProminent)      // analogous to .borderedProminent
Button("Button") {}.buttonStyle(.glass(.clear))
```
Use these instead of hand-rolling `glassEffect` on a `Button`: "Instead of creating buttons with custom Liquid Glass effects, you can adopt the look and feel of the material with minimal code."

### 2.4 Scroll edge effects and edge-to-edge content

**`backgroundExtensionEffect()` — macOS 26.0+ (also iOS/iPadOS/tvOS/visionOS/watchOS 26.0)** — Mirrors + blurs the view's edges into adjacent safe area so content appears to run under a sidebar/inspector.
```swift
@MainActor @preconcurrency func backgroundExtensionEffect() -> some View

NavigationSplitView {
    // sidebar
} detail: {
    ZStack { BannerView().backgroundExtensionEffect() }
}
```
"Apply this modifier with discretion… often used with only a single instance of background content." It **clips** the view to prevent mirrored copies overlapping. Apply it to the *image only*, then overlay text/buttons, or the overlay will also be mirrored under the sidebar.

**`scrollEdgeEffectStyle(_:for:)` — macOS 26.0+** — Chooses hard/soft/none legibility treatment between scrolling content and controls.
```swift
nonisolated func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View

ScrollView { LazyVStack { ForEach(data) { RowView($0) } } }
    .scrollEdgeEffectStyle(.hard, for: .all)
```

**`ScrollEdgeEffectStyle` — macOS 26.0+**
```swift
struct ScrollEdgeEffectStyle
static var hard: ScrollEdgeEffectStyle { get }   // "linear, nearly opaque boundary"
static var soft: ScrollEdgeEffectStyle { get }   // "subtle, blurred boundary"
```
**Apple's rule is to prefer the default.** HIG Scroll views: "**Prefer the automatic scroll edge effect style.** Where possible, use the default `automatic` style… This style provides a more opaque visual separation for top toolbars that contain a large number of controls, text that appears outside of Liquid Glass controls, and pinned table headers. If you use the soft scroll edge effect style instead, thoroughly test your interface to ensure your controls maintain legibility in a variety of contexts." Also: "Only use a scroll edge effect when a scroll view is behind floating interface elements. Scroll edge effects aren't decorative." Remove it entirely with `scrollEdgeEffectHidden(_:for:)` (macOS 26.0+, signature `nonisolated func scrollEdgeEffectHidden(_ hidden: Bool = true, for edges: Edge.Set = .all) -> some View`).

**`safeAreaBar(edge:alignment:spacing:content:)` — macOS 26.0+** — Registers a custom bar so the system applies the scroll edge effect and safe area to it.
```swift
nonisolated func safeAreaBar(edge: HorizontalEdge, alignment: VerticalAlignment = .center,
                             spacing: CGFloat? = nil, @ContentBuilder content: () -> some View) -> some View
```
Apple: "If you use a custom bar with elements like controls, text, or icons that have content scrolling beneath them, you can register those views to use a scroll edge effect with these APIs."

### 2.5 Toolbars

**`ToolbarSpacer` — macOS 26.0+** — "A standard space item in toolbars", used to divide glass groups.
```swift
nonisolated struct ToolbarSpacer

.toolbar {
    ToolbarSpacer(.flexible)
    ToolbarItem { ShareLink(item: landmark) }
    ToolbarSpacer(.fixed)
    ToolbarItemGroup { FavoriteButton(); CollectionsMenu() }
}
```

**`SpacerSizing` — macOS 26.0+** — `static let fixed: SpacerSizing` / `static let flexible: SpacerSizing`. Fixed = system-defined break; flexible = pushes items apart. Spacers are user-customizable in customizable toolbars.

**`visibilityPriority(_:)` — macOS 26.1+ (iOS/iPadOS/tvOS/visionOS/watchOS 27.0)** — ⚠️ *not* macOS 26.0. Controls overflow order.
```swift
@MainActor @preconcurrency func visibilityPriority(_ priority: ToolbarItemVisibilityPriority) -> some ToolbarContent

ToolbarItem { PrimaryControl() }.visibilityPriority(.high)
```
`ToolbarItemVisibilityPriority`: `.automatic`, `.low`, `.high`, plus `init(lowerThan:)` / `init(higherThan:)`. Lower priority moves to the overflow menu first.

**`toolbar(id:content:)` — macOS 11.0+ (not new)** — Enables user toolbar customization; required if you want `ToolbarSpacer`s to be user-editable.
```swift
nonisolated func toolbar<Content>(id: String, @ContentBuilder content: () -> Content) -> some View
    where Content : CustomizableToolbarContent
```

**`ToolbarOverflowMenu` — iOS 27.0 / iPadOS 27.0 / Mac Catalyst 27.0 / visionOS 27.0 — NOT available on macOS.** Cannot be used. On macOS the system supplies the overflow menu itself.

**`toolbarMinimizationBehavior(_:for:)` + `ToolbarMinimizationBehavior` — macOS 27.0+ (all platforms 27.0)** — macOS 27 addition.
```swift
nonisolated func toolbarMinimizationBehavior(_ behavior: ToolbarMinimizationBehavior,
                                            for bars: ToolbarPlacement...) -> some View

NavigationStack { ScrollView { /* … */ } }
    .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
```
Cases: `.automatic`, `.never`, `.onScrollDown`, `.onScrollUp`. Apple's own examples are iOS navigation-bar centric; on macOS the effect is on window toolbars.

**`toolbar(removing:)` + `ToolbarDefaultItemKind` — macOS 14.0+ (NOT a macOS 26 API)**
```swift
nonisolated func toolbar(removing defaultItemKind: ToolbarDefaultItemKind?) -> some View

NavigationSplitView { SidebarView().toolbar(removing: .sidebarToggle) } detail: { DetailView() }
```

**`toolbarVisibility(_:for:)` — macOS 15.0+** — `nonisolated func toolbarVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View`; useful to hide the toolbar in a full-window viewer.

**`ToolbarContent.hidden(_:)` — macOS 15.0+** — `nonisolated func hidden(_ hidden: Bool = true) -> some ToolbarContent`; hide the item, not its contents.

### 2.6 Shapes and concentricity

**`ConcentricRectangle` — macOS 26.0+** — "A shape whose corners you configure, individually or uniformly, to be squared, rounded, or concentric relative to a container shape's corners."
```swift
struct ConcentricRectangle
init(corners: Edge.Corner.Style, isUniform: Bool = false)

content.padding().background(ConcentricRectangle(corners: .concentric).fill(.background))
```
**`Edge.Corner.Style` — macOS 26.0+** — the corner vocabulary used by both APIs: `static var concentric: Edge.Corner.Style { get }` ("a rounded corner style where the corner's radius shares a center…") and `static func fixed(_ radius: CGFloat) -> Edge.Corner.Style`.

Concentric means the corner radius "shares a common center with the containing shape's rounded corner radius".

**`Shape.rect(corners:isUniform:)` — macOS 26.0+**
```swift
@export(implementation) static func rect(corners: Edge.Corner.Style, isUniform: Bool = false) -> Self

.glassEffect(.regular, in: .rect(corners: .concentric, isUniform: false))
```

**`containerShape(_:)` — the overload Apple documents today is macOS 26.0+**
```swift
nonisolated func containerShape(_ shape: some RoundedRectangularShape) -> some View

content.padding().containerShape(RoundedRectangle(cornerRadius: 20))
    .background(RoundedRectangle(cornerRadius: 20).fill(.background))
```
Sets the shape that descendant `ContainerRelativeShape` and `ConcentricRectangle` resolve against. Apple's `containerShape` sample uses exactly the `.background(shape.fill(.background))` pattern.

### 2.7 Navigation and tabs

| Symbol | Availability | Note |
|---|---|---|
| `TabViewStyle.sidebarAdaptable` | macOS 15.0+ | "macOS and tvOS always show a sidebar" |
| `Tab` | macOS 15.0+ | `struct Tab<Value, Content, Label>` |
| `TabSection` | macOS 15.0+ | Hierarchy inside a tab view |
| `TabRole.prominent` | **macOS 27.0+** | Trailing, separate tab position |
| `TabRole.search` | macOS 15.0+ | System separates search from other tabs |

For this app the important point: **`NavigationSplitView` is already the recommended structure** — you do not need to convert to `TabView(.sidebarAdaptable)` on macOS just for Liquid Glass; the tab style is for apps whose navigation *is* tab-based.

### 2.8 macOS 27 additions (26-only vs 27-only)

| API | Introduced | Kind |
|---|---|---|
| `NSGlassEffectView.effectIsInteractive` | **macOS 27.0** | `var effectIsInteractive: Bool { get set }` — "Enables interactive glass behavior… The default value is `NO`." Set it for glass used as the background of, or container for, interactive controls. macOS 26 has no equivalent. |
| `ToolbarMinimizationBehavior` + `toolbarMinimizationBehavior(_:for:)` | **macOS 27.0** | Toolbar reacts to scrolling |
| `ToolbarItemVisibilityPriority` + `visibilityPriority(_:)` | **macOS 26.1** (other platforms 27.0) | Overflow ordering |
| `TabRole.prominent` | **macOS 27.0** | Prominent tab |
| `ToolbarOverflowMenu` | iOS 27 / visionOS 27 only | **Not on macOS** |
| `ToolbarItemPlacement.topBarPinnedTrailing` | iOS 27 / visionOS 27 only | **Not on macOS** |
| `glassEffectUnion(id:namespace:)` | macOS 26.0 | 26-only API |
| `ContentBuilder` (unified replacement for `ToolbarContentBuilder`, `CommandsBuilder`) | Xcode 27 era | Build-time, from SwiftUI updates |

Everything else in §2 is **macOS 26.0** and unchanged in 27.

### 2.9 AppKit equivalents (for any non-SwiftUI code in the app)

| Symbol | Availability | Purpose |
|---|---|---|
| `NSGlassEffectView` | macOS 26.0 | Embeds `contentView` in glass; `cornerRadius`, `tintColor`, `style` (`.regular`, `.clear`) |
| `NSGlassEffectView.effectIsInteractive` | macOS 27.0 | Visual response to interaction; **default `NO`** |
| `NSGlassEffectContainerView` | macOS 26.0 | AppKit equivalent of `GlassEffectContainer` ("efficiently merge these views when they're in proximity") |
| `NSBackgroundExtensionView` | macOS 26.0 | AppKit equivalent of `backgroundExtensionEffect()` |
| `NSButton.BezelStyle.glass` | macOS 26.0 | Liquid Glass button bezel |
| `NSToolbarItem.Style.prominent` + `NSToolbarItem.backgroundTintColor` | macOS 26.0 | Tint standout toolbar items |

### 2.10 Could not verify / does not exist

- **`MinimizedToolbarBehavior`** — no such symbol. The real type is `ToolbarMinimizationBehavior` (macOS 27.0+).
- **`.toolbarMinimizationBehavior(_:)`** (single argument) — does not exist; the signature takes `for bars: ToolbarPlacement...`.
- **`ToolbarOverflowMenu` on macOS** — the symbol exists but Apple lists no macOS availability; do not ship it in a Mac-only path.
- **`ToolbarSpacer` initializer parameter list** — the `init(_:visible:)` page did not resolve, so the exact signature is not quoted. The call forms `ToolbarSpacer(.fixed)` / `ToolbarSpacer(.flexible)` **are** verified from Apple's own Landmarks sample.
- **`.containerShape(_:)` historical `Shape`-taking overload** — the page Apple serves today documents only the macOS 26.0 `RoundedRectangularShape` overload; I could not verify the availability of the older generic overload from Apple's current pages.
- **`NSGlassEffectView.Style` individual case pages** — case list (`clear`, `regular`) is taken from the `NSGlassEffectView.Style` topic list, not from separately fetched case pages.
- **HIG Typography** — no Liquid Glass-specific section exists in the first 100 KB of Apple's Typography page JSON; the only typography change I can trace is the section-header capitalization rule in *Adopting Liquid Glass*.

---

## 3. HIG rules you must not violate

### 3.1 Content layer vs functional layer — the rule that decides everything

> "Liquid Glass forms a distinct functional layer for controls and navigation elements — like tab bars and sidebars — that floats above the content layer… **Don't use Liquid Glass in the content layer.** Liquid Glass works best when it provides a clear distinction between interactive elements and content, and including it in the content layer can result in unnecessary complexity and a confusing visual hierarchy. Instead, use standard materials for elements in the content layer, such as app backgrounds." — HIG Materials

- **One documented exception:** "controls in the content layer with a transient interactive element like sliders and toggles; in these cases, the element takes on a Liquid Glass appearance to emphasize its interactivity when a person activates it."
- "**Use Liquid Glass effects sparingly**… Limit these effects to the most important functional elements in your app."
- Variant rule: use **`regular`** "when background content might create legibility issues, or when components have a significant amount of text, such as alerts, sidebars, or popovers." Use **`clear`** "for components that float above media backgrounds — such as photos and videos — to create a more immersive content experience." If the underlying media is bright, add a "dark dimming layer of 35% opacity"; if it is already dark (or you use standard AVKit controls that dim themselves), no dimming layer is needed.

### 3.2 Concentric corner radii / nesting

- "Across Apple platforms, the shape of the hardware informs the curvature, size, and shape of nested interface elements… Help maintain a sense of visual continuity by using rounded shapes that are concentric to their containers" — *Adopting Liquid Glass*, which names `Shape.rect(corners:isUniform:)` and `ConcentricRectangle`.
- **Toolbar rule:** "standard buttons, text fields, headers, and footers have corner radii that are concentric with bar corners. If you need to create a custom component, ensure that its corner radius is also concentric with the bar's corners." — HIG Toolbars.
- A corner is concentric when "the corner's radius shares a common center with the containing shape's rounded corner radius." Use `isUniform: true` when you want one symmetric radius (the system picks the largest); `false` lets corners differ when the rectangle is off-center in its container.
- **Nesting hygiene:** "Check for crowding or overlapping of controls… avoid overcrowding or layering Liquid Glass elements on top of each other."

### 3.3 Toolbar ordering, grouping and hit targets

- Three zones — **leading** (navigation + title + document menu; *not* customizable), **center** (customizable; automatically collapses into the system overflow as the window shrinks), **trailing** (always visible; inspectors, search, More, and the primary action). "Items on the trailing edge remain visible at all window sizes."
- "**Group toolbar items logically by function and frequency of use**… aim for a maximum of three" groups. Group items that "perform similar actions or affect the same part of the interface."
- "**Keep actions with text labels separate**" — mixing a symbol button and a text button in one group "can create the illusion of a single action"; separate them with fixed space.
- "**Use the `.prominent` style for key actions such as Done or Submit**… Only specify one primary action, and put it on the trailing side."
- "The system automatically adds an overflow menu in macOS or iPadOS when items no longer fit. **Don't add an overflow menu manually**, and avoid layouts that cause toolbar items to overflow by default."
- "Make every toolbar item available as a command in the menu bar" — the toolbar can't be the only path to a command.
- **Hit target:** "As a general rule, a button needs a hit region of **at least 44x44 pt**… to ensure that people can select it easily." (HIG Buttons.) Apple also says to prefer standard spacing metrics rather than overriding them, and to test that nothing overlaps.
- Don't mix text and icons across items that share a glass background; give every icon an accessibility label.

### 3.4 Sidebars and windows

- **Sidebars:** "Extend visually rich content beneath the sidebar… you can extend content beneath the sidebar either by letting it horizontally scroll or by applying a background extension effect." Also: show no more than two levels of hierarchy; let people hide the sidebar but don't hide it by default; don't put critical info/actions at the bottom (window relocations hide it); macOS sidebar row height/text/glyph size follow the small/medium/large setting.
- **Windows:** "Windows adopt rounder corners to fit controls and navigation elements." Support arbitrary window sizes; use layout guides/safe areas so the system can adjust window controls and title bar; use split views for fluid resizing. HIG Layout adds: "**Differentiate controls from content… Instead of applying a solid or semi-opaque background color beneath controls, use a scroll edge effect to visually elevate controls above content**" and "For full-screen background content, be sure to extend it underneath sidebars, toolbars, and tab bars."
- **Sheets/popovers:** check content near the rounder sheet corners, check what peeks through the inset half-sheet, and remove custom visual-effect background views in popovers.
- **Scroll edge effects:** "Prefer the automatic scroll edge effect style." Use `.hard`/`.soft` only when the automatic style "isn't appropriate for your content and controls", and never use an edge effect decoratively — "Only use a scroll edge effect when a scroll view is behind floating interface elements."

### 3.5 Typography and color

- **Typography:** section headers now use title-style capitalization — Apple: "Make sure to update your section headers to title-style capitalization to match your app's text to this systemwide convention." Forms should use the grouped form style to pick up layout metrics. Keep window titles under ~15 characters and never title a window with the app name. (No Liquid Glass-specific typography section exists in HIG Typography.)
- **Color:** "Liquid Glass has no inherent color… it takes on colors from the content directly behind it." "**Apply color sparingly to the Liquid Glass material, and to symbols or text on the material**… To emphasize primary actions, apply color to the background rather than to symbols or text… **Refrain from adding color to the background of multiple controls**." For colorful content, "prefer a monochromatic appearance for toolbars and tab bars." "**Avoid applying a similar color to toolbar item labels and content layer backgrounds.**" If you define custom colors, "supply light and dark variants, and an increased contrast option for each" — and "Even if your app ships in a single appearance mode, provide both light and dark colors to support Liquid Glass adaptivity." Don't repurpose dynamic system colors (never `.separator` as text or `.secondaryLabel` as a background).
- **Lists/forms:** larger row height and padding, increased section corner radius; don't mask or round row images yourself because focused rows get rounded corners.

---

## 4. Adoption checklist for this app shape

### 4.1 Which custom surfaces become glass

| Surface | Verdict | Why |
|---|---|---|
| Sidebar `List(.sidebar)` | **Free — already glass.** Remove any custom background/appearance override. | It is a functional-layer navigation element |
| Toolbar `ToolbarItem`s | **Free — already glass.** Add `ToolbarSpacer` groupings; drop tinted/custom toolbar backgrounds. | "Reduce the use of toolbar backgrounds and tinted controls" |
| Detail-area **cards** (`controlBackgroundColor` + `strokeBorder`) | **Stay plain — do NOT add `glassEffect`.** | They are the content layer; "Don't use Liquid Glass in the content layer" |
| Card **container shapes/radii** | **Change** — `ConcentricRectangle` / `.containerShape(_:)` | Concentricity, not material, is the macOS 26 change for cards |
| Settings **`Form(.grouped)`** | **Free — already glass-adjacent.** Convert section headers to title-style caps; remove custom row backgrounds. | Grouped form is a system component |
| Full-window **photo viewer (dark)** | **Keep the photo plain (content layer). Controls over it may use `.glass(.clear)`, with a dimming layer if the media is bright.** | HIG Materials: clear is "for components that float above media backgrounds" |
| Floating functional overlays over detail content (e.g. a hover action cluster, badge) | **May be glass** — the one legitimate custom-`glassEffect` use here | Transient functional element above content |
| `NavigationSplitView` itself | **Free.** Remove custom backgrounds. | Named explicitly in Apple's "remove custom effects" list |

### 4.2 Full-bleed dark photo viewer — concrete plan

1. The photo itself is **content**: never apply `glassEffect` to it.
2. Wrap it so the *viewer* is dark (`.background(.black)` / `.preferredColorScheme(.dark)` on the viewer) and let the system decide toolbar/sidebar appearance.
3. If the viewer is the detail column of the split view, apply `.backgroundExtensionEffect()` to the image **only** (before any overlay), so it mirrors under the sidebar — this is exactly Apple's Landmarks pattern.
4. Controls floating over the photo: `.buttonStyle(.glass(.clear))`, and add a dimming layer beneath when the photo is bright — Apple's own sample: `.glassEffect(.clear).background(.black.opacity(0.3))`. Skip the dimming layer if you use standard AVKit playback controls, which dim themselves.
5. Where the photo runs edge-to-edge with no floating controls over it, remove the legibility treatment for that edge with `.scrollEdgeEffectHidden(true, for: ...)`; otherwise keep the default automatic style (Apple explicitly prefers it) and only reach for `.hard`/`.soft` deliberately. Consider `.toolbarVisibility(.hidden, for: .windowToolbar)` (macOS 15+) or `WindowStyle.hiddenTitleBar` (macOS 11+) for a true full-window mode — and always leave a discoverable way back.
6. With `NSGlassEffectView` on macOS 26, remember `effectIsInteractive` does not exist — on macOS 27 set `effectIsInteractive = true` explicitly (default is `NO`).

### 4.3 Should cards switch to a new container API?

- **Material:** no. Cards are content-layer surfaces — keep an opaque/standard-material fill. Apple's own concentric sample uses `.background(shape.fill(.background))`, i.e. a *standard* style, not glass.
- **Shape:** yes. Replace hard-coded `RoundedRectangle(cornerRadius: N)` + `strokeBorder` with a concentric shape and declare the container shape on the ancestor:
```swift
// before
card.background(Color(nsColor: .controlBackgroundColor),
               in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

// after (macOS 26+, gated)
card.containerShape(RoundedRectangle(cornerRadius: 12))
    .background(ConcentricRectangle(corners: .concentric).fill(.background))
    .overlay(ConcentricRectangle(corners: .concentric).strokeBorder(.separator))
```
- **Colors:** `Color(nsColor: .controlBackgroundColor)` is a hard-coded semantic choice that will not track the new materials. Prefer `.background`/`Material` styles, and if you keep custom colors, supply light, dark and increased-contrast variants.

### 4.4 Do / Don't

**Do**
- Do gate all macOS 26+/27 APIs with `if #available(macOS 26.0, *)` / `27.0` while the deployment target is 14.
- Do group toolbar items with `ToolbarSpacer(.fixed)` between functional groups and `.flexible` to push a group to the trailing edge.
- Do keep the primary action (Done/Save) trailing and uniquely `.prominent` / `.glassProminent`.
- Do put every custom glass cluster inside a `GlassEffectContainer` and give morphing shapes `glassEffectID(_:in:)` in a shared `Namespace`.
- Do use `backgroundExtensionEffect()` on the single hero image in the detail column.
- Do use concentric shapes for every rounded element nested in a bar, card, sheet or window corner.
- Do add accessibility labels to icon-only toolbar items, and test Reduce Transparency / Increase Contrast / Reduce Motion.

**Don't**
- Don't apply `glassEffect` to cards, list rows, form rows, or any content-layer background.
- Don't hand-roll glass on buttons — use `.buttonStyle(.glass)`/`.glassProminent`.
- Don't paint custom backgrounds on `NavigationSplitView`, the sidebar, the toolbar, sheets or popovers.
- Don't add your own toolbar overflow menu on macOS (the system provides it; `ToolbarOverflowMenu` isn't even available on macOS).
- Don't tint the background of more than one control, and don't tint toolbar labels to match the content behind them.
- Don't place multiple Liquid Glass elements on top of one another or exceed ~3 toolbar groups.
- Don't hard-code control size/layout metrics, or you lose the automatic metric refresh.
- Don't rely on `.visibilityPriority` at macOS 26.0 — it starts at 26.1.

---

## 5. URLs fetched

**Technology overviews & updates**
- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/updates/swiftui
- https://developer.apple.com/documentation/updates/appkit
- https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility

**SwiftUI — glass material**
- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- https://developer.apple.com/documentation/swiftui/glass
- https://developer.apple.com/documentation/swiftui/glass/regular · /identity · /clear · /tint(_:) · /interactive(_:)
- https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass

**SwiftUI — containers, IDs, transitions**
- https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- https://developer.apple.com/documentation/swiftui/glasseffectcontainer/init(spacing:content:)
- https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)
- https://developer.apple.com/documentation/swiftui/glasseffecttransition · /materialize · /matchedgeometry
- https://developer.apple.com/documentation/swiftui/view/glasseffecttransition(_:)
- https://developer.apple.com/documentation/swiftui/view/glasseffectunion(id:namespace:)

**SwiftUI — buttons**
- https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass · /glassprominent · /glass(_:)
- https://developer.apple.com/documentation/swiftui/glassbuttonstyle · /glassprominentbuttonstyle

**SwiftUI — scroll edges, bars, edge-to-edge**
- https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)
- https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle · /hard · /soft
- https://developer.apple.com/documentation/swiftui/view/scrolledgeeffecthidden(_:for:)
- https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()
- https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:)

**SwiftUI — toolbars**
- https://developer.apple.com/documentation/swiftui/toolbarspacer
- https://developer.apple.com/documentation/swiftui/spacersizing · /fixed · /flexible
- https://developer.apple.com/documentation/swiftui/view/toolbar(id:content:)
- https://developer.apple.com/documentation/swiftui/view/toolbar(removing:)
- https://developer.apple.com/documentation/swiftui/toolbardefaultitemkind · /sidebartoggle
- https://developer.apple.com/documentation/swiftui/toolbarcontent/visibilitypriority(_:)
- https://developer.apple.com/documentation/swiftui/toolbaritemvisibilitypriority
- https://developer.apple.com/documentation/swiftui/toolbaroverflowmenu
- https://developer.apple.com/documentation/swiftui/view/toolbarminimizationbehavior(_:for:)
- https://developer.apple.com/documentation/swiftui/toolbarminimizationbehavior
- https://developer.apple.com/documentation/swiftui/view/toolbarvisibility(_:for:)
- https://developer.apple.com/documentation/swiftui/toolbarcontent/hidden(_:)
- https://developer.apple.com/documentation/swiftui/toolbaritemplacement/topbarpinnedtrailing

**SwiftUI — shapes, containers, tabs**
- https://developer.apple.com/documentation/swiftui/concentricrectangle
- https://developer.apple.com/documentation/swiftui/concentricrectangle/init(corners:isuniform:)
- https://developer.apple.com/documentation/swiftui/shape/rect(corners:isuniform:)
- https://developer.apple.com/documentation/swiftui/view/containershape(_:)
- https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable
- https://developer.apple.com/documentation/swiftui/tab
- https://developer.apple.com/documentation/swiftui/tabrole/prominent
- https://developer.apple.com/documentation/swiftui/windowstyle/hiddentitlebar

**AppKit**
- https://developer.apple.com/documentation/appkit/nsglasseffectview
- https://developer.apple.com/documentation/appkit/nsglasseffectview/effectisinteractive
- https://developer.apple.com/documentation/appkit/nsglasseffectview/tintcolor · /cornerradius
- https://developer.apple.com/documentation/appkit/nsglasseffectview/style-swift.enum
- https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview
- https://developer.apple.com/documentation/appkit/nsbackgroundextensionview
- https://developer.apple.com/documentation/appkit/nsbutton/bezelstyle-swift.enum/glass
- https://developer.apple.com/documentation/appkit/nstoolbaritem/style-swift.enum/prominent · /backgroundtintcolor
- https://developer.apple.com/documentation/appkit/nsview/preferscompactcontrolsizemetrics

**Human Interface Guidelines**
- https://developer.apple.com/design/human-interface-guidelines/materials
- https://developer.apple.com/design/human-interface-guidelines/color
- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/buttons
- https://developer.apple.com/design/human-interface-guidelines/windows
- https://developer.apple.com/design/human-interface-guidelines/layout
- https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
- https://developer.apple.com/design/human-interface-guidelines/split-views
- https://developer.apple.com/design/human-interface-guidelines/scroll-views
- https://developer.apple.com/design/human-interface-guidelines/typography
