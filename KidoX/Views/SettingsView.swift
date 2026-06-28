import AppKit
import KeyboardShortcuts
import KidoXIPC
import LaunchAtLogin
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared state

/// Holds the currently selected settings pane.
@Observable
@MainActor
final class SettingsState {
    var selection: SettingsPane? = .general
    var currentPane: SettingsPane { selection ?? .general }
}

// MARK: - Pane model

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case uninstaller
    case hiddenApps
    case advanced
    case license
    case about

    var id: String { rawValue }

    var title: String {
        title(languageRawValue: nil)
    }

    func title(languageRawValue: String?) -> String {
        switch self {
        case .general:    KidoXL10n.string(.general, languageRawValue: languageRawValue)
        case .appearance: KidoXL10n.string(.appearance, languageRawValue: languageRawValue)
        case .uninstaller: KidoXL10n.ui("Uninstaller", languageRawValue: languageRawValue)
        case .hiddenApps: KidoXL10n.string(.hiddenApps, languageRawValue: languageRawValue)
        case .advanced:   KidoXL10n.string(.advanced, languageRawValue: languageRawValue)
        case .license:    KidoXL10n.string(.license, languageRawValue: languageRawValue)
        case .about:      KidoXL10n.string(.about, languageRawValue: languageRawValue)
        }
    }

    var symbolName: String {
        switch self {
        case .general:    "gearshape"
        case .appearance: "paintbrush"
        case .uninstaller: "trash"
        case .hiddenApps: "eye.slash"
        case .advanced:   "shippingbox"
        case .license:    "key"
        case .about:      "info.circle"
        }
    }
}

// MARK: - Sidebar view

/// The left-hand navigation list hosted inside the NSSplitViewItem sidebar.
struct SidebarView: View {
    var state: SettingsState

    @State private var availableVersion = KidoXUpdaterController.shared.availableVersion
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsPane.allCases) { pane in
                SidebarItemView(
                    title: pane.title(languageRawValue: appLanguageRaw),
                    symbolName: pane.symbolName,
                    isSelected: state.currentPane == pane
                ) {
                    state.selection = pane
                }
            }

            Spacer()

            if let availableVersion {
                SidebarActionButton(
                    title: KidoXL10n.format(.versionAvailable, availableVersion, languageRawValue: appLanguageRaw),
                    symbolName: "arrow.down.circle.fill",
                    accent: true
                ) {
                    KidoXUpdaterController.shared.showAvailableUpdate(orderOutSettingsWindow: true)
                }
                .padding(.horizontal, 8)
            }

            // Help Center at the bottom
            Button {
                NSWorkspace.shared.open(KidoXAppConfiguration.helpURL)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14))
                    Text(KidoXL10n.string(.helpCenter, languageRawValue: appLanguageRaw))
                        .font(.body)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            refreshAvailableVersion()
        }
        .onReceive(NotificationCenter.default.publisher(for: KidoXUpdaterController.updateAvailabilityDidChangeNotification)) { _ in
            refreshAvailableVersion()
        }
    }

    private func refreshAvailableVersion() {
        availableVersion = KidoXUpdaterController.shared.availableVersion
    }
}

struct SidebarItemView: View {
    let title: String
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct SidebarActionButton: View {
    let title: String
    let symbolName: String
    let accent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.body)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((accent ? Color.accentColor : Color.primary).opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Detail view

/// The right-hand content area hosted inside the plain NSSplitViewItem.
struct DetailView: View {
    var state: SettingsState
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Page title mirrors the selected sidebar item
            Text(state.currentPane.title(languageRawValue: appLanguageRaw))
                .font(.title2.bold())
                .padding(.horizontal, 28)
                .padding(.top, 48)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))

            switch state.currentPane {
            case .general:    GeneralPane()
            case .appearance: AppearancePane(state: state)
            case .uninstaller: UninstallerSettingsPane(state: state)
            case .hiddenApps: HiddenAppsPane()
            case .advanced:   AdvancedPane(state: state)
            case .license:    LicensePane()
            case .about:      AboutPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)) // Light gray background
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @AppStorage(KidoXLanguage.storageKey)
    private var appLanguageRaw = KidoXLanguage.system.rawValue
    @AppStorage(StatusItemController.showMenuBarIconStorageKey)
    private var showMenuBarIcon = true
    @AppStorage(KidoXActivationPreferenceKeys.f4HotKeyEnabled)
    private var f4HotKeyEnabled = true
    @AppStorage(KidoXActivationPreferenceKeys.hotCorner)
    private var hotCorner = KidoXHotCorner.none.rawValue

    @State private var dockIcon = KidoXDockIconPreference.current.rawValue
    @State private var isDockIconShown = KidoXDockPinning.isKidoXAppPinned()
    @State private var isAccessibilityAccessGranted = KidoXActivationController.isAccessibilityAccessGranted

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Picker("", selection: $appLanguageRaw) {
                        ForEach(KidoXLanguage.allCases) { language in
                            Text(language.localizedTitle).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KidoXL10n.string(.appLanguage, languageRawValue: appLanguageRaw))
                        Text(KidoXL10n.string(.appLanguageDescription, languageRawValue: appLanguageRaw))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(KidoXL10n.string(.language, languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))

            Section {
                VStack(alignment: .leading, spacing: 3) {
                    LaunchAtLogin.Toggle(KidoXL10n.ui("Launch at login", languageRawValue: appLanguageRaw))
                    Text(KidoXL10n.ui("KidoX will launch in the background when system starts", languageRawValue: appLanguageRaw))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(KidoXL10n.ui("Show in menu bar", languageRawValue: appLanguageRaw), isOn: $showMenuBarIcon)

                LabeledContent {
                    HStack(spacing: 8) {
                        if f4HotKeyEnabled && !isAccessibilityAccessGranted {
                            Button(KidoXL10n.ui("Grant Access", languageRawValue: appLanguageRaw)) {
                                KidoXActivationController.requestAccessibilityAccess()
                                refreshAccessibilityAccessState()
                            }
                            .controlSize(.small)
                        }

                        Toggle("", isOn: $f4HotKeyEnabled)
                            .labelsHidden()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KidoXL10n.ui("Launch with F4", languageRawValue: appLanguageRaw))
                        Text(f4HotKeyDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .showLaunchPanel)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KidoXL10n.ui("Keyboard shortcut", languageRawValue: appLanguageRaw))
                        Text(KidoXL10n.ui("Show KidoX from anywhere.", languageRawValue: appLanguageRaw))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Picker("", selection: $hotCorner) {
                        ForEach(KidoXHotCorner.allCases) { corner in
                            Text(corner.localizedTitle(languageRawValue: appLanguageRaw)).tag(corner.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KidoXL10n.ui("Hot Corner", languageRawValue: appLanguageRaw))
                        Text(KidoXL10n.ui("Move the pointer into a screen corner to show KidoX.", languageRawValue: appLanguageRaw))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor)) // White card background

            Section {
                if !isDockIconShown {
                    LabeledContent(KidoXL10n.ui("Show Dock Icon", languageRawValue: appLanguageRaw)) {
                        Button(KidoXL10n.ui("Show", languageRawValue: appLanguageRaw)) {
                            KidoXDockPinning.pinKidoXAppIfNeeded()
                            refreshDockIconShownState()
                        }
                    }
                }

                LabeledContent(KidoXL10n.ui("Dock icon", languageRawValue: appLanguageRaw)) {
                    HStack(spacing: 8) {
                        ForEach(KidoXDockIcon.allCases) { icon in
                            DockIconPreviewButton(
                                icon: icon,
                                isSelected: dockIcon == icon.rawValue
                            ) {
                                dockIcon = icon.rawValue
                            }
                        }
                    }
                    .fixedSize()
                }
                .onChange(of: dockIcon) { _, newValue in
                    let icon = KidoXDockIcon(rawValue: newValue) ?? .standard
                    KidoXDockIconPreference.apply(icon)
                }
            } header: {
                Text(KidoXL10n.ui("Dock", languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor)) // White card background
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden) // Hide native Form background
        .background(Color(nsColor: .windowBackgroundColor)) // Use system gray background
        .onAppear {
            refreshDockIconShownState()
            refreshAccessibilityAccessState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityAccessState()
        }
    }

    private var f4HotKeyDescription: String {
        if !f4HotKeyEnabled {
            return KidoXL10n.ui("Turn on to open KidoX with the F4 or Launchpad key.", languageRawValue: appLanguageRaw)
        }

        if isAccessibilityAccessGranted {
            return KidoXL10n.ui("Open KidoX with the F4 or Launchpad key, without changing system keyboard settings.", languageRawValue: appLanguageRaw)
        }

        return KidoXL10n.ui("Grant Accessibility to capture the F4 or Launchpad key without changing system keyboard settings.", languageRawValue: appLanguageRaw)
    }

    private func refreshAccessibilityAccessState() {
        isAccessibilityAccessGranted = KidoXActivationController.isAccessibilityAccessGranted
    }

    private func refreshDockIconShownState() {
        let isPinned = KidoXDockPinning.isKidoXAppPinned()
        if isDockIconShown != isPinned {
            isDockIconShown = isPinned
        }
    }
}

private struct AppearancePane: View {
    var state: SettingsState

    @AppStorage(KidoXLanguage.storageKey)
    private var appLanguageRaw = KidoXLanguage.system.rawValue
    @AppStorage(KidoXBackgroundStyle.styleStorageKey)
    private var backgroundStyleRaw = KidoXBackgroundStyle.wallpaper.rawValue
    @AppStorage(KidoXPanelController.showMenuBarStorageKey)
    private var showMenuBar = false
    @AppStorage(KidoXBackgroundStyle.wallpaperBlurStorageKey)
    private var wallpaperBlurRadius = 24.0
    @AppStorage(KidoXBackgroundStyle.wallpaperDarkenStorageKey)
    private var wallpaperDarkenOpacity = 0.18
    @AppStorage(KidoXBackgroundStyle.imageBlurStorageKey)
    private var imageBlurRadius = 24.0
    @AppStorage(KidoXBackgroundStyle.imageDarkenStorageKey)
    private var imageDarkenOpacity = 0.18
    @AppStorage(KidoXBackgroundStyle.glassStrengthStorageKey)
    private var glassStrength = 0.5
    @AppStorage(KidoXBackgroundStyle.solidPresetStorageKey)
    private var solidPresetRaw = KidoXSolidBackgroundPreset.graphite.rawValue
    @AppStorage(KidoXBackgroundStyle.solidCustomColorStorageKey)
    private var solidCustomColorHex = KidoXSolidBackgroundPreset.defaultCustomColorHex
    @AppStorage(KidoXBackgroundStyle.customImagePathStorageKey)
    private var customImagePath = ""
    @AppStorage("ClyAppLicense.status")
    private var licenseStatus = "Free"
    @State private var imageImportError: String?

    private var isPro: Bool {
        licenseStatus == "active"
    }

    private var backgroundStyle: KidoXBackgroundStyle {
        KidoXBackgroundStyle(storageValue: backgroundStyleRaw)
    }

    private var backgroundStyleBinding: Binding<KidoXBackgroundStyle> {
        Binding {
            backgroundStyle
        } set: { newValue in
            backgroundStyleRaw = newValue.rawValue
        }
    }

    private var solidPreset: KidoXSolidBackgroundPreset {
        let preset = KidoXSolidBackgroundPreset(storageValue: solidPresetRaw)
        return isPro || !preset.requiresPro ? preset : .graphite
    }

    private var solidCustomColorBinding: Binding<Color> {
        Binding {
            Color(hexRGB: solidCustomColorHex) ?? KidoXSolidBackgroundPreset.defaultCustomColor
        } set: { newValue in
            guard isPro else {
                state.selection = .license
                return
            }
            solidPresetRaw = KidoXSolidBackgroundPreset.custom.rawValue
            solidCustomColorHex = newValue.hexRGBString ?? KidoXSolidBackgroundPreset.defaultCustomColorHex
        }
    }

    private func selectSolidPreset(_ preset: KidoXSolidBackgroundPreset) {
        guard isPro || !preset.requiresPro else {
            state.selection = .license
            return
        }
        solidPresetRaw = preset.rawValue
    }

    private func chooseCustomImage() {
        guard isPro else {
            state.selection = .license
            return
        }

        NotificationCenter.default.post(
            name: KidoXPanelController.hideLaunchPanelForModalPresentationNotification,
            object: nil
        )

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            customImagePath = try KidoXCustomWallpaperStore.copyImage(from: url)
            backgroundStyleRaw = KidoXBackgroundStyle.image.rawValue
        } catch {
            imageImportError = error.localizedDescription
        }
    }

    private func deleteCustomImage() {
        let path = customImagePath
        customImagePath = ""

        if backgroundStyle == .image {
            backgroundStyleRaw = KidoXBackgroundStyle.wallpaper.rawValue
        }

        KidoXCustomWallpaperStore.deleteImage(at: path)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(KidoXL10n.ui("Style", languageRawValue: appLanguageRaw)) {
                    Picker("", selection: backgroundStyleBinding) {
                        ForEach(KidoXBackgroundStyle.allCases) { style in
                            Text(style.localizedTitle(languageRawValue: appLanguageRaw)).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                selectedBackgroundControls
            } header: {
                Text(KidoXL10n.ui("Background", languageRawValue: appLanguageRaw))
            } footer: {
                Text(backgroundStyle.localizedDescription(languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))

            Section {
                Toggle(KidoXL10n.ui("Show menu bar", languageRawValue: appLanguageRaw), isOn: $showMenuBar)
            } header: {
                Text(KidoXL10n.ui("Menu Bar", languageRawValue: appLanguageRaw))
            } footer: {
                Text(KidoXL10n.ui(
                    showMenuBar ? "KidoX stays below the menu bar while open." : "KidoX covers the menu bar while open.",
                    languageRawValue: appLanguageRaw
                ))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(KidoXL10n.ui("Image Import Failed", languageRawValue: appLanguageRaw), isPresented: Binding(
            get: { imageImportError != nil },
            set: { if !$0 { imageImportError = nil } }
        )) {
            Button(KidoXL10n.ui("OK", languageRawValue: appLanguageRaw), role: .cancel) {
                imageImportError = nil
            }
        } message: {
            Text(imageImportError ?? "")
        }
    }

    @ViewBuilder
    private var selectedBackgroundControls: some View {
        switch backgroundStyle {
        case .wallpaper:
            wallpaperControls
        case .image:
            customImageControls
        case .glass:
            glassControls
        case .solid:
            solidControls
        }
    }

    private var wallpaperControls: some View {
        backgroundImageAdjustmentControls(
            blur: $wallpaperBlurRadius,
            brightness: $wallpaperDarkenOpacity
        )
    }

    private var imageAdjustmentControls: some View {
        backgroundImageAdjustmentControls(
            blur: $imageBlurRadius,
            brightness: $imageDarkenOpacity
        )
    }

    private func backgroundImageAdjustmentControls(
        blur: Binding<Double>,
        brightness: Binding<Double>
    ) -> some View {
        Group {
            LabeledContent(KidoXL10n.ui("Blur", languageRawValue: appLanguageRaw)) {
                EndpointLabeledSlider(
                    value: blur,
                    range: 0...48,
                    leadingLabel: KidoXL10n.ui("Clear", languageRawValue: appLanguageRaw),
                    trailingLabel: KidoXL10n.ui("Blurred", languageRawValue: appLanguageRaw)
                )
            }

            LabeledContent(KidoXL10n.ui("Brightness", languageRawValue: appLanguageRaw)) {
                EndpointLabeledSlider(
                    value: brightness,
                    range: -0.32...0.45,
                    leadingLabel: KidoXL10n.ui("Brighter", languageRawValue: appLanguageRaw),
                    trailingLabel: KidoXL10n.ui("Darker", languageRawValue: appLanguageRaw)
                )
            }
        }
    }

    private var customImageControls: some View {
        Group {
            LabeledContent {
                if customImagePath.isEmpty {
                    Button(KidoXL10n.ui("Choose Image...", languageRawValue: appLanguageRaw)) {
                        chooseCustomImage()
                    }
                    .help(KidoXL10n.ui(
                        isPro ? "Choose a custom wallpaper image" : "Custom wallpaper images require Pro",
                        languageRawValue: appLanguageRaw
                    ))
                } else {
                    CustomWallpaperPreview(
                        imagePath: customImagePath,
                        selectAction: {
                            chooseCustomImage()
                        },
                        deleteAction: {
                            deleteCustomImage()
                        }
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    Text(KidoXL10n.ui("Image", languageRawValue: appLanguageRaw))
                    if !isPro {
                        ProBadge()
                    }
                }
            }

            imageAdjustmentControls
        }
    }

    private var glassControls: some View {
        LabeledContent(KidoXL10n.ui("Strength", languageRawValue: appLanguageRaw)) {
            EndpointLabeledSlider(
                value: $glassStrength,
                range: 0...1,
                leadingLabel: KidoXL10n.ui("Subtle", languageRawValue: appLanguageRaw),
                trailingLabel: KidoXL10n.ui("Strong", languageRawValue: appLanguageRaw)
            )
        }
    }

    private var solidControls: some View {
        Group {
            LabeledContent(KidoXL10n.ui("Preset", languageRawValue: appLanguageRaw)) {
                HStack(spacing: 8) {
                    ForEach(KidoXSolidBackgroundPreset.builtInCases) { preset in
                        SolidPresetButton(
                            preset: preset,
                            isSelected: solidPreset == preset,
                            showsPro: !isPro && preset.requiresPro
                        ) {
                            selectSolidPreset(preset)
                        }
                    }
                }
                .fixedSize()
            }

            LabeledContent(KidoXL10n.ui("Custom", languageRawValue: appLanguageRaw)) {
                HStack(spacing: 8) {
                    ZStack {
                        ColorPicker(
                            "",
                            selection: solidCustomColorBinding,
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .fixedSize()
                        .opacity(isPro ? 1 : 0.55)
                        .allowsHitTesting(isPro)

                        if !isPro {
                            Button {
                                state.selection = .license
                            } label: {
                                Color.clear
                                    .frame(width: 28, height: 24)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !isPro {
                        ProBadge()
                    }
                }
                .help(KidoXL10n.ui(
                    isPro ? "Choose a custom solid background color" : "Custom solid background colors require Pro",
                    languageRawValue: appLanguageRaw
                ))
            }
        }
    }
}

private struct EndpointLabeledSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let leadingLabel: String
    let trailingLabel: String

    private let width: CGFloat = 160

    var body: some View {
        VStack(spacing: 3) {
            Slider(value: $value, in: range)

            HStack {
                Text(leadingLabel)
                Spacer()
                Text(trailingLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(width: width)
    }
}

private struct ProBadge: View {
    var body: some View {
        Text("Pro")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color(nsColor: .systemPurple))
    }
}

private struct CustomWallpaperPreview: View {
    let imagePath: String
    let selectAction: () -> Void
    let deleteAction: () -> Void

    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue
    @State private var image: NSImage?
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            previewImage

            if isHovered {
                Button(role: .destructive) {
                    deleteAction()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.red.opacity(0.95), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityLabel(KidoXL10n.ui("Delete image", languageRawValue: appLanguageRaw))
                .help(KidoXL10n.ui("Delete custom wallpaper image", languageRawValue: appLanguageRaw))
                .offset(x: 7, y: -7)
            }
        }
        .padding(.top, 7)
        .padding(.trailing, 7)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .task(id: imagePath) {
            image = await KidoXCustomWallpaperStore.image(at: imagePath)
        }
        .help(KidoXL10n.ui("Move pointer over the image to select another wallpaper", languageRawValue: appLanguageRaw))
    }

    private var previewImage: some View {
        previewContent
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                Color.black
                    .opacity(isHovered ? 0.28 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                Button(KidoXL10n.ui("Select", languageRawValue: appLanguageRaw)) {
                    selectAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
    }

    @ViewBuilder
    private var previewContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlColor))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct SolidPresetButton: View {
    let preset: KidoXSolidBackgroundPreset
    let isSelected: Bool
    let showsPro: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(preset.color)
                        .frame(width: 30, height: 20)
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.white.opacity(0.16))
                                .frame(height: 8)
                                .blendMode(.plusLighter)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.primary.opacity(isSelected ? 0.45 : 0.22), lineWidth: isSelected ? 1.5 : 1)
                        }

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.55), radius: 1, y: 0.5)
                    }
                }

                ProBadge()
                    .opacity(showsPro ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(showsPro ? "\(preset.title) requires Pro" : preset.title)
    }
}

private struct DockIconPreviewButton: View {
    let icon: KidoXDockIcon
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let image = icon.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 42, height: 38)

                Circle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 42, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(KidoXL10n.uiFormat("%@ Dock icon", icon.title, languageRawValue: appLanguageRaw))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .opacity(isHovered && !isSelected ? 0.82 : 1)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct UninstallerSettingsPane: View {
    var state: SettingsState

    @AppStorage(KidoXLanguage.storageKey)
    private var appLanguageRaw = KidoXLanguage.system.rawValue
    @AppStorage("ClyAppLicense.status")
    private var licenseStatus = "Free"

    @State private var helperVersion: String?
    @State private var statusMessage: String?
    @State private var statusMessageIsError = false
    @State private var isCheckingHelper = false
    @State private var isInstallingHelper = false
    @State private var hasFullDiskAccess = Self.detectFullDiskAccess()

    private let helperClient = KidoXPrivilegedHelperClient()

    private var isPro: Bool {
        licenseStatus == "active"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: dataAccessSymbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(dataAccessColor)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(dataAccessTitle)
                                    .font(.headline)
                                if !isPro { ProBadge() }
                            }

                            Text(fullDiskAccessDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isPro, !hasFullDiskAccess {
                            Button(KidoXL10n.ui("Grant Access", languageRawValue: appLanguageRaw)) {
                                openFullDiskAccessSettings()
                            }
                            .buttonStyle(.borderedProminent)
                        } else if !isPro {
                            Button(KidoXL10n.ui("Purchase Pro", languageRawValue: appLanguageRaw)) {
                                NSWorkspace.shared.open(KidoXAppConfiguration.purchaseURL)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(KidoXL10n.ui("Full Disk Access", languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: advancedUninstallSymbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(advancedUninstallColor)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(advancedUninstallTitle)
                                    .font(.headline)
                                if !isPro { ProBadge() }
                            }

                            Text(advancedUninstallDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isInstallingHelper {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if isPro, shouldShowHelperAction {
                            Button(helperActionTitle) {
                                installHelper()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isCheckingHelper || isInstallingHelper)
                        } else if !isPro {
                            Button(KidoXL10n.ui("Purchase Pro", languageRawValue: appLanguageRaw)) {
                                NSWorkspace.shared.open(KidoXAppConfiguration.purchaseURL)
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusMessageIsError ? .red : .secondary)
                    }

                    Text(KidoXL10n.ui("Free users can uninstall apps that macOS allows KidoX to move to Trash. Pro users can install the helper to remove root-owned and many Mac App Store apps.", languageRawValue: appLanguageRaw))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text(KidoXL10n.ui("Advanced Uninstall", languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshFullDiskAccessStatus()
            refreshHelperStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFullDiskAccessStatus()
        }
    }

    private var fullDiskAccessDescription: String {
        if !isPro {
            return KidoXL10n.ui("Upgrade to Pro to scan and remove app data in protected Library folders.", languageRawValue: appLanguageRaw)
        }
        if hasFullDiskAccess {
            return KidoXL10n.ui("KidoX can access protected Library folders for app data cleanup.", languageRawValue: appLanguageRaw)
        }
        return KidoXL10n.ui("Grant Full Disk Access so KidoX can scan and remove app data in protected Library folders such as Containers and Group Containers.", languageRawValue: appLanguageRaw)
    }

    private var dataAccessSymbol: String {
        if !isPro { return "lock.shield" }
        return hasFullDiskAccess ? "checkmark.circle.fill" : "hand.raised.fill"
    }

    private var dataAccessColor: Color {
        if !isPro { return .secondary }
        return hasFullDiskAccess ? .green : .orange
    }

    private var dataAccessTitle: String {
        if !isPro {
            return KidoXL10n.ui("Data cleanup requires Pro", languageRawValue: appLanguageRaw)
        }
        return hasFullDiskAccess
            ? KidoXL10n.ui("Full Disk Access is enabled", languageRawValue: appLanguageRaw)
            : KidoXL10n.ui("Full Disk Access is not enabled", languageRawValue: appLanguageRaw)
    }

    private var advancedUninstallSymbol: String {
        if !isPro { return "lock.shield" }
        if helperVersion == nil || helperNeedsUpdate { return "shield" }
        return "checkmark.shield.fill"
    }

    private var advancedUninstallColor: Color {
        if !isPro { return .secondary }
        return helperVersion == nil || helperNeedsUpdate ? .orange : .green
    }

    private var advancedUninstallTitle: String {
        if !isPro {
            return KidoXL10n.ui("Advanced uninstall requires Pro", languageRawValue: appLanguageRaw)
        }
        if helperVersion == nil {
            return KidoXL10n.ui("Advanced uninstall is not enabled", languageRawValue: appLanguageRaw)
        }
        if helperNeedsUpdate {
            return KidoXL10n.ui("Advanced uninstall update available", languageRawValue: appLanguageRaw)
        }
        return KidoXL10n.ui("Advanced uninstall is enabled", languageRawValue: appLanguageRaw)
    }

    private var advancedUninstallDescription: String {
        if !isPro {
            return KidoXL10n.ui("Upgrade to Pro to remove apps that require administrator permission.", languageRawValue: appLanguageRaw)
        }
        if let helperVersion {
            if helperNeedsUpdate {
                return KidoXL10n.uiFormat(
                    "Helper version %@ is installed. Version %@ is available.",
                    helperVersion,
                    KidoXPrivilegedHelper.version,
                    languageRawValue: appLanguageRaw
                )
            }
            return KidoXL10n.uiFormat("Helper version %@ is installed.", helperVersion, languageRawValue: appLanguageRaw)
        }
        return KidoXL10n.ui("Install the helper once to remove root-owned and Mac App Store apps without repeated administrator prompts.", languageRawValue: appLanguageRaw)
    }

    private var shouldShowHelperAction: Bool {
        helperVersion == nil || helperNeedsUpdate
    }

    private var helperActionTitle: String {
        helperVersion == nil
            ? KidoXL10n.ui("Install Helper", languageRawValue: appLanguageRaw)
            : KidoXL10n.ui("Update Helper", languageRawValue: appLanguageRaw)
    }

    private var helperNeedsUpdate: Bool {
        guard let helperVersion else { return false }
        return helperVersion.compare(KidoXPrivilegedHelper.version, options: .numeric) == .orderedAscending
    }

    private func refreshHelperStatus() {
        guard !isCheckingHelper else { return }
        isCheckingHelper = true
        statusMessage = nil
        statusMessageIsError = false

        Task {
            do {
                let version = try await helperClient.installedHelperVersion()
                await MainActor.run {
                    helperVersion = version
                    statusMessage = nil
                    statusMessageIsError = false
                    isCheckingHelper = false
                }
            } catch {
                await MainActor.run {
                    helperVersion = nil
                    statusMessage = KidoXL10n.ui("Helper is not installed.", languageRawValue: appLanguageRaw)
                    statusMessageIsError = false
                    isCheckingHelper = false
                }
            }
        }
    }

    private func installHelper() {
        guard isPro, !isInstallingHelper else { return }
        isInstallingHelper = true
        statusMessage = KidoXL10n.ui("Waiting for administrator authorization...", languageRawValue: appLanguageRaw)
        statusMessageIsError = false

        Task {
            do {
                try await Task.detached {
                    try helperClient.installHelper()
                }.value
                let version = try await helperClient.installedHelperVersion()
                await MainActor.run {
                    helperVersion = version
                    statusMessage = nil
                    statusMessageIsError = false
                    isInstallingHelper = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    statusMessageIsError = true
                    isInstallingHelper = false
                }
            }
        }
    }

    private func refreshFullDiskAccessStatus() {
        hasFullDiskAccess = Self.detectFullDiskAccess()
    }

    private func openFullDiskAccessSettings() {
        let candidateURLs = [
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        ]

        for url in candidateURLs.compactMap({ $0 }) {
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private static func detectFullDiskAccess() -> Bool {
        let fileManager = FileManager.default
        let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        let probeURLs = [
            libraryURL?.appendingPathComponent("Mail", isDirectory: true),
            libraryURL?.appendingPathComponent("Messages", isDirectory: true),
            libraryURL?.appendingPathComponent("Safari", isDirectory: true)
        ].compactMap { $0 }

        var testedProtectedLocation = false
        for url in probeURLs where fileManager.fileExists(atPath: url.path) {
            testedProtectedLocation = true
            if (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) != nil {
                return true
            }
        }

        return !testedProtectedLocation
    }
}

private struct HiddenAppsPane: View {
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue
    @State private var pages: [LaunchPage] = []
    @State private var isLoading = false
    @State private var addError: String?

    private let database = KidoXDatabase()

    private var hiddenApps: [LaunchItem] {
        pages
            .flatMap(\.items)
            .filter { $0.kind == .application && $0.isHidden }
            .sorted {
                $0.effectiveDisplayName.localizedStandardCompare($1.effectiveDisplayName) == .orderedAscending
            }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Button {
                        addApps()
                    } label: {
                        Label(KidoXL10n.ui("Add App...", languageRawValue: appLanguageRaw), systemImage: "plus")
                    }
                    .controlSize(.small)

                    Spacer(minLength: 0)
                }

                if let addError {
                    Label(addError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if isLoading && pages.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if hiddenApps.isEmpty {
                    Text(KidoXL10n.ui("No hidden apps.", languageRawValue: appLanguageRaw))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(hiddenApps) { item in
                        HiddenAppRow(item: item) {
                            restore(item)
                        }
                    }
                }
            } header: {
                Text(KidoXL10n.ui("Apps", languageRawValue: appLanguageRaw))
            } footer: {
                Text(KidoXL10n.ui("Restored apps return to the page or folder where they were hidden. Manually added apps restore to the first available page.", languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        pages = await database.loadPagesAsync()
    }

    private func addApps() {
        NotificationCenter.default.post(
            name: KidoXPanelController.hideLaunchPanelForModalPresentationNotification,
            object: nil
        )

        let panel = NSOpenPanel()
        panel.title = KidoXL10n.ui("Add Hidden Apps", languageRawValue: appLanguageRaw)
        panel.prompt = KidoXL10n.ui("Hide", languageRawValue: appLanguageRaw)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK else { return }
        addApplications(at: panel.urls)
    }

    private func addApplications(at urls: [URL]) {
        var didChange = false
        var failedNames: [String] = []

        for url in urls {
            guard var item = ApplicationScanner.makeApplicationItem(url: url) else {
                failedNames.append(url.lastPathComponent)
                continue
            }

            if updateExistingApplication(with: item) {
                didChange = true
            } else if !containsApplication(matching: item) {
                appendHiddenApplication(&item)
                didChange = true
            }
        }

        if didChange {
            database.savePages(pages)
            NotificationCenter.default.post(name: .kidoXPagesDidChangeExternally, object: nil)
        }

        if failedNames.isEmpty {
            addError = nil
        } else {
            addError = "Could not add \(failedNames.joined(separator: ", "))."
        }
    }

    private func updateExistingApplication(with selectedItem: LaunchItem) -> Bool {
        let selectedKey = applicationKey(for: selectedItem)

        for pageIndex in pages.indices {
            if let itemIndex = pages[pageIndex].items.firstIndex(where: { item in
                item.kind == .application && applicationKey(for: item) == selectedKey
            }) {
                let original = pages[pageIndex].items[itemIndex]
                pages[pageIndex].items[itemIndex].displayName = selectedItem.displayName
                pages[pageIndex].items[itemIndex].subtitle = selectedItem.subtitle
                pages[pageIndex].items[itemIndex].url = selectedItem.url
                pages[pageIndex].items[itemIndex].bundleIdentifier = selectedItem.bundleIdentifier
                pages[pageIndex].items[itemIndex].bundleName = selectedItem.bundleName
                pages[pageIndex].items[itemIndex].localizedDisplayNames = selectedItem.localizedDisplayNames
                pages[pageIndex].items[itemIndex].applicationCategory = selectedItem.applicationCategory
                pages[pageIndex].items[itemIndex].version = selectedItem.version
                pages[pageIndex].items[itemIndex].sourcePath = selectedItem.sourcePath
                pages[pageIndex].items[itemIndex].isHidden = true
                return pages[pageIndex].items[itemIndex] != original
            }
        }

        return false
    }

    private func containsApplication(matching selectedItem: LaunchItem) -> Bool {
        let selectedKey = applicationKey(for: selectedItem)
        return pages.flatMap(\.items).contains { item in
            item.kind == .application && applicationKey(for: item) == selectedKey
        }
    }

    private func appendHiddenApplication(_ item: inout LaunchItem) {
        if pages.isEmpty {
            pages.append(LaunchPage(sortIndex: 0))
        }

        let orderedPageIndices = pages.indices.sorted { pages[$0].sortIndex < pages[$1].sortIndex }
        let targetPageIndex = orderedPageIndices.first { pageIndex in
            pages[pageIndex].rootItems.count < LaunchPage.defaultCapacity
        }

        let pageIndex: Int
        if let targetPageIndex {
            pageIndex = targetPageIndex
        } else {
            let nextPageIndex = (pages.map(\.sortIndex).max() ?? -1) + 1
            pages.append(LaunchPage(sortIndex: nextPageIndex))
            pageIndex = pages.count - 1
        }

        let nextSortIndex = (pages[pageIndex].items
            .filter { $0.parentID == nil }
            .map(\.sortIndex)
            .max() ?? -1) + 1

        item.isHidden = true
        item.parentID = nil
        item.sortIndex = nextSortIndex
        pages[pageIndex].items.append(item)
    }

    private func applicationKey(for item: LaunchItem) -> String {
        item.bundleIdentifier ?? item.sourcePath
    }

    private func restore(_ item: LaunchItem) {
        guard let location = itemLocation(for: item.id) else { return }
        pages[location.pageIndex].items[location.itemIndex].isHidden = false
        database.savePages(pages)
        NotificationCenter.default.post(name: .kidoXPagesDidChangeExternally, object: nil)
    }

    private func itemLocation(for id: LaunchItem.ID) -> (pageIndex: Int, itemIndex: Int)? {
        for pageIndex in pages.indices {
            if let itemIndex = pages[pageIndex].items.firstIndex(where: { $0.id == id }) {
                return (pageIndex, itemIndex)
            }
        }
        return nil
    }
}

private struct HiddenAppRow: View {
    let item: LaunchItem
    let restore: () -> Void
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.rasterizedIcon(for: item.sourcePath, pointSize: 28))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.effectiveDisplayName)
                    .lineLimit(1)
                Text(item.subtitle.isEmpty ? item.sourcePath : item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(KidoXL10n.ui("Restore", languageRawValue: appLanguageRaw), action: restore)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

private struct AdvancedPane: View {
    var state: SettingsState

    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue
    @AppStorage("ClyAppLicense.status")
    private var licenseStatus = "Free"
    @AppStorage(KidoXActivationPreferenceKeys.debugLoggingEnabled)
    private var debugLoggingEnabled = false
    @State private var exportMessage: AdvancedTransferMessage?
    @State private var importMessage: AdvancedTransferMessage?
    @State private var debugMessage: AdvancedTransferMessage?
    @State private var isWorking = false

    private var isPro: Bool {
        licenseStatus == "active"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        exportBackup()
                    } label: {
                        Label(KidoXL10n.ui("Export Backup...", languageRawValue: appLanguageRaw), systemImage: "square.and.arrow.up")
                    }
                    .disabled(isWorking)
                    .help(KidoXL10n.ui(isPro ? "Export KidoX backup" : "Backup export requires Pro", languageRawValue: appLanguageRaw))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(KidoXL10n.ui("Backup File", languageRawValue: appLanguageRaw))
                            if !isPro {
                                ProBadge()
                            }
                        }
                        Text(KidoXL10n.ui("Save your current KidoX data to a file.", languageRawValue: appLanguageRaw))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let exportMessage {
                    AdvancedStatusLabel(message: exportMessage)
                }
            } header: {
                Text(KidoXL10n.ui("Export", languageRawValue: appLanguageRaw))
            } footer: {
                Text(KidoXL10n.ui("Includes layout, hidden apps, usage stats, sorting, keyboard shortcut, appearance, Dock icon, and custom image. License and launch-at-login stay on this Mac.", languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer(minLength: 0)

                        Button {
                            importBackup()
                        } label: {
                            Label(KidoXL10n.ui("Import Backup...", languageRawValue: appLanguageRaw), systemImage: "square.and.arrow.down")
                        }
                        .disabled(isWorking)
                        .help(KidoXL10n.ui(isPro ? "Import KidoX backup" : "Backup import requires Pro", languageRawValue: appLanguageRaw))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(KidoXL10n.ui("Restore From File", languageRawValue: appLanguageRaw))
                            if !isPro {
                                ProBadge()
                            }
                        }
                        Text(KidoXL10n.ui("Replace this Mac's current KidoX data.", languageRawValue: appLanguageRaw))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let importMessage {
                    AdvancedStatusLabel(message: importMessage)
                }
            } header: {
                Text(KidoXL10n.ui("Import", languageRawValue: appLanguageRaw))
            } footer: {
                Text(KidoXL10n.ui("Import replaces the current layout and settings. Apps that are not installed on this Mac are skipped and shown in the result.", languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))

            Section {
                LabeledContent {
                    Toggle("", isOn: $debugLoggingEnabled)
                        .labelsHidden()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KidoXL10n.ui("Debug", languageRawValue: appLanguageRaw))
                        Text(KidoXL10n.ui("Record app debug logs.", languageRawValue: appLanguageRaw))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button {
                        exportDebugLog()
                    } label: {
                        Label(KidoXL10n.ui("Export Log...", languageRawValue: appLanguageRaw), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KidoXL10n.ui("Export Log", languageRawValue: appLanguageRaw))
                        Text(KidoXL10n.ui("Save recent debug logs to a file.", languageRawValue: appLanguageRaw))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let debugMessage {
                    AdvancedStatusLabel(message: debugMessage)
                }
            } header: {
                Text(KidoXL10n.ui("Debug", languageRawValue: appLanguageRaw))
            } footer: {
                Text(KidoXL10n.ui("Use this only when sharing logs with support. Leave it off for normal use.", languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func exportBackup() {
        guard isPro else {
            state.selection = .license
            return
        }

        NotificationCenter.default.post(
            name: KidoXPanelController.hideLaunchPanelForModalPresentationNotification,
            object: nil
        )

        let panel = NSSavePanel()
        panel.title = KidoXL10n.ui("Export KidoX Backup", languageRawValue: appLanguageRaw)
        panel.prompt = KidoXL10n.ui("Export", languageRawValue: appLanguageRaw)
        panel.nameFieldStringValue = defaultBackupFilename()
        panel.allowedContentTypes = [.kidoXBackup]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try KidoXBackupManager.exportBackup(to: url)
            exportMessage = AdvancedTransferMessage(text: KidoXL10n.ui("Backup exported.", languageRawValue: appLanguageRaw), kind: .success)
        } catch {
            exportMessage = AdvancedTransferMessage(text: error.localizedDescription, kind: .failure)
        }
    }

    private func importBackup() {
        guard isPro else {
            state.selection = .license
            return
        }

        NotificationCenter.default.post(
            name: KidoXPanelController.hideLaunchPanelForModalPresentationNotification,
            object: nil
        )

        let panel = NSOpenPanel()
        panel.title = KidoXL10n.ui("Import KidoX Backup", languageRawValue: appLanguageRaw)
        panel.prompt = KidoXL10n.ui("Import", languageRawValue: appLanguageRaw)
        panel.allowedContentTypes = [.kidoXBackup, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirmImport() else { return }

        isWorking = true
        importMessage = nil

        Task { @MainActor in
            defer { isWorking = false }

            do {
                let result = try await KidoXBackupManager.importBackup(from: url)
                importMessage = AdvancedTransferMessage(text: result.summary, kind: .success)
            } catch {
                importMessage = AdvancedTransferMessage(text: error.localizedDescription, kind: .failure)
            }
        }
    }

    private func confirmImport() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = KidoXL10n.ui("Import KidoX Backup?", languageRawValue: appLanguageRaw)
        alert.informativeText = KidoXL10n.ui("This replaces the current layout and settings. Apps that are not installed on this Mac will be skipped and reported after import.", languageRawValue: appLanguageRaw)
        alert.addButton(withTitle: KidoXL10n.ui("Import", languageRawValue: appLanguageRaw))
        alert.addButton(withTitle: KidoXL10n.string(.cancel, languageRawValue: appLanguageRaw))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func defaultBackupFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "KidoX Backup \(formatter.string(from: Date())).kidoxbackup"
    }

    private func exportDebugLog() {
        NotificationCenter.default.post(
            name: KidoXPanelController.hideLaunchPanelForModalPresentationNotification,
            object: nil
        )

        let panel = NSSavePanel()
        panel.title = KidoXL10n.ui("Export KidoX Log", languageRawValue: appLanguageRaw)
        panel.prompt = KidoXL10n.ui("Export", languageRawValue: appLanguageRaw)
        panel.nameFieldStringValue = defaultLogFilename()
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try KidoXLogExporter.exportAppLog(to: url, debugLoggingEnabled: debugLoggingEnabled)
            debugMessage = AdvancedTransferMessage(text: KidoXL10n.ui("Log exported.", languageRawValue: appLanguageRaw), kind: .success)
        } catch {
            debugMessage = AdvancedTransferMessage(text: error.localizedDescription, kind: .failure)
        }
    }

    private func defaultLogFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "KidoX Log \(formatter.string(from: Date())).log"
    }
}

private enum KidoXLogExporter {
    static func exportAppLog(to url: URL, debugLoggingEnabled: Bool) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--style",
            "compact",
            "--info",
            "--debug",
            "--last",
            "15m",
            "--predicate",
            #"subsystem == "com.clyapps.KidoX""#
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw KidoXLogExportError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let exportedAt = ISO8601DateFormatter().string(from: Date())
        let content = [
            "KidoX Debug Log",
            "Exported At: \(exportedAt)",
            "Debug Enabled: \(debugLoggingEnabled)",
            "Range: last 15 minutes",
            "Levels: info, debug, default",
            "Included Logs: KidoX app logs",
            "",
            output.isEmpty ? "No matching log entries found." : output
        ].joined(separator: "\n")

        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum KidoXLogExportError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            if output.isEmpty {
                return "Log export failed."
            }
            return "Log export failed: \(output)"
        }
    }
}

private struct AdvancedStatusLabel: View {
    let message: AdvancedTransferMessage

    var body: some View {
        Label(message.text, systemImage: message.kind.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(message.kind.color)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }
}

private struct AboutPane: View {
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)

                VStack(spacing: 4) {
                    Text(appName)
                        .font(.title2.weight(.semibold))

                    Text(KidoXL10n.uiFormat("Version %@ (%@)", appVersion, buildNumber, languageRawValue: appLanguageRaw))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button(KidoXL10n.ui("Check for Update", languageRawValue: appLanguageRaw)) {
                    KidoXUpdaterController.shared.checkForUpdates(orderOutSettingsWindow: true)
                }

                Button(KidoXL10n.ui("Support", languageRawValue: appLanguageRaw)) {
                    NSWorkspace.shared.open(KidoXAppConfiguration.supportURL)
                }

                Button(KidoXL10n.ui("Website", languageRawValue: appLanguageRaw)) {
                    NSWorkspace.shared.open(KidoXAppConfiguration.websiteURL)
                }
            }
            .controlSize(.large)

            Spacer()
        }
        .padding(.top, 56)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "KidoX"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

}

private extension KidoXDockIcon {
    var previewResourceName: String {
        switch self {
        case .standard: "KidoX"
        case .minimal: "KidoXMinimal"
        }
    }

    var previewImage: NSImage? {
        if let url = Bundle.main.url(forResource: previewResourceName, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSImage(named: NSImage.Name(previewResourceName))
    }
}

private struct LicensePane: View {
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue
    @AppStorage("ClyAppLicense.status")        private var licenseStatus = "Free"
    @AppStorage("ClyAppLicense.plan")          private var licensePlan = "Free"
    @AppStorage("ClyAppLicense.activationID")  private var activationID = ""
    @AppStorage("ClyAppLicense.licensePrefix") private var licensePrefix = ""
    @AppStorage("ClyAppLicense.licenseKey")    private var storedLicenseKey = ""
    @AppStorage("ClyAppLicense.entitlementType") private var entitlementType = ""
    @AppStorage("ClyAppLicense.trialEndsAt")   private var trialEndsAt = ""

    @State private var licenseKey = ""
    @State private var activationMessage: ActivationMessage?
    @State private var isActivating = false
    @State private var isDeactivating = false

    private var isPro: Bool { licenseStatus == "active" }
    private var isTrial: Bool { isPro && entitlementType == "trial" }
    private var isPaidLicense: Bool { isPro && !isTrial }

    var body: some View {
        Form {
            Section {
                LicenseStatusCard(
                    isPro: isPro,
                    isTrial: isTrial,
                    planTitle: planTitle,
                    statusText: statusText,
                    showsDeactivate: isPaidLicense && !activationID.isEmpty,
                    isDeactivating: isDeactivating,
                    purchaseAction: openPurchaseLicense,
                    deactivateAction: {
                        Task { await deactivate() }
                    }
                )
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))

            if !isPaidLicense {
                Section {
                    LabeledContent {
                        TextField("", text: $licenseKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 260)
                            .onSubmit { Task { await activate() } }
                    } label: {
                        Text(KidoXL10n.ui("License Key", languageRawValue: appLanguageRaw))
                    }

                    HStack(spacing: 8) {
                        Button(KidoXL10n.ui("Purchase License", languageRawValue: appLanguageRaw)) {
                            openPurchaseLicense()
                        }

                        Spacer(minLength: 0)

                        Button {
                            Task { await activate() }
                        } label: {
                            Group {
                                if isActivating { ProgressView().controlSize(.small) }
                                else { Text(KidoXL10n.ui("Activate", languageRawValue: appLanguageRaw)) }
                            }
                            .frame(minWidth: 64)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedKey.isEmpty || isActivating)
                    }
                    .padding(.vertical, 3)

                    if let msg = activationMessage {
                        ActivationStatusLabel(message: msg)
                    }
                } header: {
                    Text(KidoXL10n.ui("Activation", languageRawValue: appLanguageRaw))
                }
                .listRowBackground(Color(nsColor: .controlBackgroundColor))
            }

            Section {
                ProFeatureRow(
                    symbol: "arrow.up.arrow.down",
                    title: KidoXL10n.ui("Advanced sorting", languageRawValue: appLanguageRaw),
                    subtitle: KidoXL10n.ui("Recently used, most used, recently added, and name-based ordering.", languageRawValue: appLanguageRaw),
                    showsPro: !isPro
                )
                ProFeatureRow(
                    symbol: "eye.slash",
                    title: KidoXL10n.ui("Hide apps", languageRawValue: appLanguageRaw),
                    subtitle: KidoXL10n.ui("Keep selected apps out of the launch panel without deleting layout data.", languageRawValue: appLanguageRaw),
                    showsPro: !isPro
                )
                ProFeatureRow(
                    symbol: "paintbrush.pointed",
                    title: KidoXL10n.ui("Advanced appearance", languageRawValue: appLanguageRaw),
                    subtitle: isPro
                        ? KidoXL10n.ui("Solid colors, custom colors, and custom image backgrounds.", languageRawValue: appLanguageRaw)
                        : KidoXL10n.ui("Unlock solid colors, custom colors, and custom image backgrounds.", languageRawValue: appLanguageRaw),
                    showsPro: !isPro
                )
                ProFeatureRow(
                    symbol: "trash",
                    title: KidoXL10n.ui("Uninstaller", languageRawValue: appLanguageRaw),
                    subtitle: KidoXL10n.ui("Remove app data and apps that require administrator permission.", languageRawValue: appLanguageRaw),
                    showsPro: !isPro
                )
                ProFeatureRow(
                    symbol: "shippingbox",
                    title: KidoXL10n.ui("Backup and restore", languageRawValue: appLanguageRaw),
                    subtitle: KidoXL10n.ui("Move your layout and settings between Macs.", languageRawValue: appLanguageRaw),
                    showsPro: !isPro
                )
            } header: {
                Text(KidoXL10n.ui(isPro ? "Included With Your License" : "Included With Pro", languageRawValue: appLanguageRaw))
            }
            .listRowBackground(Color(nsColor: .controlBackgroundColor))
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var trimmedKey: String { licenseKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var planTitle: String {
        if isTrial { return "KidoX Pro Trial" }
        return isPro ? "KidoX \(licensePlan.capitalized)" : "KidoX Free"
    }

    private var statusText: String {
        if isTrial {
            return trialEndText
        }
        if activationID.isEmpty { return KidoXL10n.ui("No active license on this Mac.", languageRawValue: appLanguageRaw) }
        if !storedLicenseKey.isEmpty {
            return KidoXL10n.uiFormat("Activated with license %@.", storedLicenseKey, languageRawValue: appLanguageRaw)
        }
        if licensePrefix.isEmpty { return KidoXL10n.ui("Activated on this Mac.", languageRawValue: appLanguageRaw) }
        return KidoXL10n.uiFormat("Activated with license %@...", licensePrefix, languageRawValue: appLanguageRaw)
    }

    private var trialEndText: String {
        guard let endDate = Self.iso8601Formatter.date(from: trialEndsAt) else {
            return KidoXL10n.ui("Your 7-day Pro trial is active.", languageRawValue: appLanguageRaw)
        }

        if endDate <= Date() {
            return KidoXL10n.ui("Your Pro trial has ended.", languageRawValue: appLanguageRaw)
        }

        let formatted = DateFormatter.localizedString(from: endDate, dateStyle: .medium, timeStyle: .short)
        return KidoXL10n.uiFormat("Your Pro trial ends %@.", formatted, languageRawValue: appLanguageRaw)
    }

    @MainActor private func activate() async {
        let key = trimmedKey
        guard !key.isEmpty, !isActivating else { return }
        isActivating = true; activationMessage = nil
        defer { isActivating = false }
        do {
            let r = try await ClyAppLicenseService.shared.activate(licenseKey: key)
            licenseStatus = r.status; licensePlan = r.plan
            activationID = r.activationID; licensePrefix = r.licensePrefix
            entitlementType = "license"; trialEndsAt = ""
            storedLicenseKey = key
            licenseKey = ""
            activationMessage = ActivationMessage(text: KidoXL10n.uiFormat("License activated for %@.", r.bundleID, languageRawValue: appLanguageRaw), kind: .success)
        } catch {
            activationMessage = ActivationMessage(text: error.localizedDescription, kind: .failure)
        }
    }

    @MainActor private func deactivate() async {
        guard !isDeactivating else { return }
        isDeactivating = true
        activationMessage = nil
        defer { isDeactivating = false }

        do {
            try await ClyAppLicenseService.shared.deactivateStoredLicense()
            activationMessage = ActivationMessage(text: KidoXL10n.ui("License deactivated on this Mac.", languageRawValue: appLanguageRaw), kind: .success)
        } catch {
            activationMessage = ActivationMessage(text: error.localizedDescription, kind: .failure)
        }
    }

    private func openPurchaseLicense() {
        NSWorkspace.shared.open(KidoXAppConfiguration.purchaseURL)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Helpers

private struct ActivationMessage: Equatable {
    enum Kind {
        case success, failure, info
        var color: Color {
            switch self { case .success: .green; case .failure: .red; case .info: .secondary }
        }
        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .failure: "exclamationmark.triangle.fill"
            case .info:    "info.circle.fill"
            }
        }
    }
    let text: String
    let kind: Kind
}

private struct LicenseStatusCard: View {
    let isPro: Bool
    let isTrial: Bool
    let planTitle: String
    let statusText: String
    let showsDeactivate: Bool
    let isDeactivating: Bool
    let purchaseAction: () -> Void
    let deactivateAction: () -> Void
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(isPro ? 0.16 : 0.10))
                        .frame(width: 42, height: 42)

                    Image(systemName: isPro ? "checkmark.seal.fill" : "seal")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(planTitle)
                            .font(.headline)

                        LicensePlanBadge(isPro: isPro, isTrial: isTrial)
                    }

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
            }

            if isPro {
                Divider()

                HStack(spacing: 8) {
                    Button(KidoXL10n.ui("Purchase License", languageRawValue: appLanguageRaw), action: purchaseAction)

                    Spacer(minLength: 0)

                    if showsDeactivate {
                        Button(role: .destructive, action: deactivateAction) {
                            Text(KidoXL10n.ui(isDeactivating ? "Deactivating" : "Deactivate This Mac", languageRawValue: appLanguageRaw))
                        }
                        .disabled(isDeactivating)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 7)
    }

    private var statusColor: Color {
        isPro ? .green : .secondary
    }
}

private struct LicensePlanBadge: View {
    let isPro: Bool
    let isTrial: Bool

    var body: some View {
        Text(badgeText)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(badgeColor)
            .background(
                badgeColor.opacity(0.14),
                in: Capsule()
            )
    }

    private var badgeText: String {
        if isTrial { return "Trial" }
        return isPro ? "Active" : "Free"
    }

    private var badgeColor: Color {
        if isTrial { return .blue }
        return isPro ? .green : .secondary
    }
}

private struct ActivationStatusLabel: View {
    let message: ActivationMessage

    var body: some View {
        Label(message.text, systemImage: message.kind.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(message.kind.color)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }
}

private struct AdvancedTransferMessage: Equatable {
    enum Kind {
        case success
        case failure

        var color: Color {
            switch self {
            case .success: .green
            case .failure: .red
            }
        }

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .failure: "exclamationmark.triangle.fill"
            }
        }
    }

    let text: String
    let kind: Kind
}

private struct KidoXBackupImportResult {
    let importedItemCount: Int
    let skippedMissingAppCount: Int
    let skippedMissingAppNames: [String]

    var summary: String {
        if skippedMissingAppCount == 0 {
            return "Backup imported. \(importedItemCount) items restored."
        }

        let visibleNames = skippedMissingAppNames.prefix(5).joined(separator: ", ")
        let suffix = skippedMissingAppCount > 5 ? ", and \(skippedMissingAppCount - 5) more" : ""
        return "Backup imported. \(importedItemCount) items restored, \(skippedMissingAppCount) missing apps skipped: \(visibleNames)\(suffix)."
    }
}

private enum KidoXBackupError: LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            "The backup contains invalid image data."
        }
    }
}

private struct KidoXBackupFile: Codable {
    var filename: String
    var base64Data: String
}

private struct KidoXBackupPreferences: Codable {
    var showMenuBarIcon: Bool
    var f4HotKeyEnabled: Bool
    var debugLoggingEnabled: Bool
    var showLaunchPanelShortcut: KeyboardShortcuts.Shortcut?
    var hotCorner: String
    var dockIcon: String
    var showMenuBarInLaunchPanel: Bool
    var launchSort: String
    var backgroundStyle: String
    var wallpaperBlur: Double
    var wallpaperDarken: Double
    var imageBlur: Double
    var imageDarken: Double
    var glassStrength: Double
    var solidPreset: String
    var solidCustomColor: String

    private enum CodingKeys: String, CodingKey {
        case showMenuBarIcon
        case f4HotKeyEnabled
        case legacyHotKeyEnabled = "hotKeyEnabled"
        case debugLoggingEnabled
        case showLaunchPanelShortcut
        case hotCorner
        case dockIcon
        case showMenuBarInLaunchPanel
        case launchSort
        case backgroundStyle
        case wallpaperBlur
        case wallpaperDarken
        case imageBlur
        case imageDarken
        case glassStrength
        case solidPreset
        case solidCustomColor
    }

    init(
        showMenuBarIcon: Bool,
        f4HotKeyEnabled: Bool,
        debugLoggingEnabled: Bool,
        showLaunchPanelShortcut: KeyboardShortcuts.Shortcut?,
        hotCorner: String,
        dockIcon: String,
        showMenuBarInLaunchPanel: Bool,
        launchSort: String,
        backgroundStyle: String,
        wallpaperBlur: Double,
        wallpaperDarken: Double,
        imageBlur: Double,
        imageDarken: Double,
        glassStrength: Double,
        solidPreset: String,
        solidCustomColor: String
    ) {
        self.showMenuBarIcon = showMenuBarIcon
        self.f4HotKeyEnabled = f4HotKeyEnabled
        self.debugLoggingEnabled = debugLoggingEnabled
        self.showLaunchPanelShortcut = showLaunchPanelShortcut
        self.hotCorner = hotCorner
        self.dockIcon = dockIcon
        self.showMenuBarInLaunchPanel = showMenuBarInLaunchPanel
        self.launchSort = launchSort
        self.backgroundStyle = backgroundStyle
        self.wallpaperBlur = wallpaperBlur
        self.wallpaperDarken = wallpaperDarken
        self.imageBlur = imageBlur
        self.imageDarken = imageDarken
        self.glassStrength = glassStrength
        self.solidPreset = solidPreset
        self.solidCustomColor = solidCustomColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showMenuBarIcon = try container.decode(Bool.self, forKey: .showMenuBarIcon)
        f4HotKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .f4HotKeyEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .legacyHotKeyEnabled)
            ?? true
        debugLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? false
        showLaunchPanelShortcut = try container.decodeIfPresent(KeyboardShortcuts.Shortcut.self, forKey: .showLaunchPanelShortcut)
        hotCorner = try container.decode(String.self, forKey: .hotCorner)
        dockIcon = try container.decode(String.self, forKey: .dockIcon)
        showMenuBarInLaunchPanel = try container.decode(Bool.self, forKey: .showMenuBarInLaunchPanel)
        launchSort = try container.decode(String.self, forKey: .launchSort)
        backgroundStyle = try container.decode(String.self, forKey: .backgroundStyle)
        wallpaperBlur = try container.decode(Double.self, forKey: .wallpaperBlur)
        wallpaperDarken = try container.decode(Double.self, forKey: .wallpaperDarken)
        imageBlur = try container.decode(Double.self, forKey: .imageBlur)
        imageDarken = try container.decode(Double.self, forKey: .imageDarken)
        glassStrength = try container.decode(Double.self, forKey: .glassStrength)
        solidPreset = try container.decode(String.self, forKey: .solidPreset)
        solidCustomColor = try container.decode(String.self, forKey: .solidCustomColor)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(f4HotKeyEnabled, forKey: .f4HotKeyEnabled)
        try container.encode(debugLoggingEnabled, forKey: .debugLoggingEnabled)
        try container.encode(showLaunchPanelShortcut, forKey: .showLaunchPanelShortcut)
        try container.encode(hotCorner, forKey: .hotCorner)
        try container.encode(dockIcon, forKey: .dockIcon)
        try container.encode(showMenuBarInLaunchPanel, forKey: .showMenuBarInLaunchPanel)
        try container.encode(launchSort, forKey: .launchSort)
        try container.encode(backgroundStyle, forKey: .backgroundStyle)
        try container.encode(wallpaperBlur, forKey: .wallpaperBlur)
        try container.encode(wallpaperDarken, forKey: .wallpaperDarken)
        try container.encode(imageBlur, forKey: .imageBlur)
        try container.encode(imageDarken, forKey: .imageDarken)
        try container.encode(glassStrength, forKey: .glassStrength)
        try container.encode(solidPreset, forKey: .solidPreset)
        try container.encode(solidCustomColor, forKey: .solidCustomColor)
    }
}

private struct KidoXBackupDocument: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var pages: [LaunchPage]
    var preferences: KidoXBackupPreferences
    var customWallpaper: KidoXBackupFile?
}

private enum KidoXBackupManager {
    @MainActor
    static func exportBackup(to url: URL) throws {
        let backup = try KidoXBackupDocument(
            schemaVersion: KidoXBackupDocument.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            pages: KidoXDatabase().loadPages(),
            preferences: currentPreferences(),
            customWallpaper: currentCustomWallpaper()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    static func importBackup(from url: URL) async throws -> KidoXBackupImportResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(KidoXBackupDocument.self, from: data)

        let localApplications = LocalApplicationIndex(items: await ApplicationScanner().scan())
        let reconciliation = reconcilePages(backup.pages, localApplications: localApplications)
        let customImagePath = try restoreCustomWallpaper(from: backup.customWallpaper)

        apply(backup.preferences, customImagePath: customImagePath)
        await KidoXDatabase().savePagesAsync(reconciliation.pages)
        NotificationCenter.default.post(name: .kidoXPagesDidChangeExternally, object: nil)

        return KidoXBackupImportResult(
            importedItemCount: reconciliation.pages.flatMap(\.items).count,
            skippedMissingAppCount: reconciliation.skippedMissingAppNames.count,
            skippedMissingAppNames: reconciliation.skippedMissingAppNames
        )
    }

    private static var appVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(shortVersion) (\(build))"
    }

    @MainActor
    private static func currentPreferences() -> KidoXBackupPreferences {
        let defaults = UserDefaults.standard
        let dockDefaults = UserDefaults(suiteName: KidoXDockIconPreference.defaultsSuiteName) ?? .standard

        return KidoXBackupPreferences(
            showMenuBarIcon: boolValue(forKey: StatusItemController.showMenuBarIconStorageKey, defaultValue: true, defaults: defaults),
            f4HotKeyEnabled: boolValue(forKey: KidoXActivationPreferenceKeys.f4HotKeyEnabled, defaultValue: true, defaults: defaults),
            debugLoggingEnabled: boolValue(forKey: KidoXActivationPreferenceKeys.debugLoggingEnabled, defaultValue: false, defaults: defaults),
            showLaunchPanelShortcut: KeyboardShortcuts.getShortcut(for: .showLaunchPanel),
            hotCorner: stringValue(forKey: KidoXActivationPreferenceKeys.hotCorner, defaultValue: KidoXHotCorner.none.rawValue, defaults: defaults),
            dockIcon: stringValue(forKey: KidoXDockIconPreference.key, defaultValue: KidoXDockIcon.standard.rawValue, defaults: dockDefaults),
            showMenuBarInLaunchPanel: boolValue(forKey: KidoXPanelController.showMenuBarStorageKey, defaultValue: false, defaults: defaults),
            launchSort: stringValue(forKey: KidoXLaunchSort.storageKey, defaultValue: KidoXLaunchSort.default.rawValue, defaults: defaults),
            backgroundStyle: stringValue(forKey: KidoXBackgroundStyle.styleStorageKey, defaultValue: KidoXBackgroundStyle.wallpaper.rawValue, defaults: defaults),
            wallpaperBlur: doubleValue(forKey: KidoXBackgroundStyle.wallpaperBlurStorageKey, defaultValue: 24, defaults: defaults),
            wallpaperDarken: doubleValue(forKey: KidoXBackgroundStyle.wallpaperDarkenStorageKey, defaultValue: 0.18, defaults: defaults),
            imageBlur: doubleValue(forKey: KidoXBackgroundStyle.imageBlurStorageKey, defaultValue: 24, defaults: defaults),
            imageDarken: doubleValue(forKey: KidoXBackgroundStyle.imageDarkenStorageKey, defaultValue: 0.18, defaults: defaults),
            glassStrength: doubleValue(forKey: KidoXBackgroundStyle.glassStrengthStorageKey, defaultValue: 0.5, defaults: defaults),
            solidPreset: stringValue(forKey: KidoXBackgroundStyle.solidPresetStorageKey, defaultValue: KidoXSolidBackgroundPreset.graphite.rawValue, defaults: defaults),
            solidCustomColor: stringValue(forKey: KidoXBackgroundStyle.solidCustomColorStorageKey, defaultValue: KidoXSolidBackgroundPreset.defaultCustomColorHex, defaults: defaults)
        )
    }

    private static func currentCustomWallpaper() throws -> KidoXBackupFile? {
        let path = UserDefaults.standard.string(forKey: KidoXBackgroundStyle.customImagePathStorageKey) ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return KidoXBackupFile(
            filename: url.lastPathComponent,
            base64Data: data.base64EncodedString()
        )
    }

    @MainActor
    private static func apply(_ preferences: KidoXBackupPreferences, customImagePath: String) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.showMenuBarIcon, forKey: StatusItemController.showMenuBarIconStorageKey)
        defaults.set(preferences.f4HotKeyEnabled, forKey: KidoXActivationPreferenceKeys.f4HotKeyEnabled)
        defaults.set(preferences.debugLoggingEnabled, forKey: KidoXActivationPreferenceKeys.debugLoggingEnabled)
        KeyboardShortcuts.setShortcut(preferences.showLaunchPanelShortcut, for: .showLaunchPanel)
        defaults.set(validHotCorner(preferences.hotCorner).rawValue, forKey: KidoXActivationPreferenceKeys.hotCorner)
        defaults.set(preferences.showMenuBarInLaunchPanel, forKey: KidoXPanelController.showMenuBarStorageKey)
        defaults.set(validLaunchSort(preferences.launchSort).rawValue, forKey: KidoXLaunchSort.storageKey)
        defaults.set(preferences.wallpaperBlur, forKey: KidoXBackgroundStyle.wallpaperBlurStorageKey)
        defaults.set(preferences.wallpaperDarken, forKey: KidoXBackgroundStyle.wallpaperDarkenStorageKey)
        defaults.set(preferences.imageBlur, forKey: KidoXBackgroundStyle.imageBlurStorageKey)
        defaults.set(preferences.imageDarken, forKey: KidoXBackgroundStyle.imageDarkenStorageKey)
        defaults.set(preferences.glassStrength, forKey: KidoXBackgroundStyle.glassStrengthStorageKey)
        defaults.set(validSolidPreset(preferences.solidPreset).rawValue, forKey: KidoXBackgroundStyle.solidPresetStorageKey)
        defaults.set(preferences.solidCustomColor, forKey: KidoXBackgroundStyle.solidCustomColorStorageKey)
        defaults.set(customImagePath, forKey: KidoXBackgroundStyle.customImagePathStorageKey)

        let preferredStyle = validBackgroundStyle(preferences.backgroundStyle)
        let resolvedStyle: KidoXBackgroundStyle = preferredStyle == .image && customImagePath.isEmpty ? .wallpaper : preferredStyle
        defaults.set(resolvedStyle.rawValue, forKey: KidoXBackgroundStyle.styleStorageKey)

        KidoXDockIconPreference.apply(validDockIcon(preferences.dockIcon))
    }

    private static func restoreCustomWallpaper(from file: KidoXBackupFile?) throws -> String {
        let existingPath = UserDefaults.standard.string(forKey: KidoXBackgroundStyle.customImagePathStorageKey) ?? ""

        guard let file else {
            KidoXCustomWallpaperStore.deleteImage(at: existingPath)
            return ""
        }

        guard let data = Data(base64Encoded: file.base64Data) else {
            throw KidoXBackupError.invalidImageData
        }

        let extensionName = URL(fileURLWithPath: file.filename).pathExtension
        let temporaryName = "KidoX-Import-\(UUID().uuidString).\(extensionName.isEmpty ? "image" : extensionName)"
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(temporaryName)
        try data.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        return try KidoXCustomWallpaperStore.copyImage(from: temporaryURL)
    }

    private struct ReconciledPages {
        var pages: [LaunchPage]
        var skippedMissingAppNames: [String]
    }

    private struct LocalApplicationIndex {
        var byBundleIdentifier: [String: LaunchItem] = [:]
        var bySourcePath: [String: LaunchItem] = [:]

        init(items: [LaunchItem]) {
            for item in items where item.kind == .application {
                if let bundleIdentifier = item.bundleIdentifier {
                    byBundleIdentifier[bundleIdentifier] = item
                }
                bySourcePath[item.sourcePath] = item
            }
        }

        func match(for importedItem: LaunchItem) -> LaunchItem? {
            if let bundleIdentifier = importedItem.bundleIdentifier,
               let item = byBundleIdentifier[bundleIdentifier] {
                return item
            }

            if let item = bySourcePath[importedItem.sourcePath] {
                return item
            }

            if FileManager.default.fileExists(atPath: importedItem.sourcePath),
               let item = ApplicationScanner.makeApplicationItem(url: URL(fileURLWithPath: importedItem.sourcePath)) {
                return item
            }

            return nil
        }
    }

    private static func reconcilePages(
        _ importedPages: [LaunchPage],
        localApplications: LocalApplicationIndex
    ) -> ReconciledPages {
        var skippedMissingAppNames: [String] = []
        var pages: [LaunchPage] = []

        for importedPage in importedPages.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            var items: [LaunchItem] = []

            for importedItem in importedPage.items {
                if importedItem.kind == .application {
                    guard let localItem = localApplications.match(for: importedItem) else {
                        skippedMissingAppNames.append(importedItem.effectiveDisplayName)
                        continue
                    }
                    items.append(mergedApplication(importedItem, with: localItem))
                } else {
                    items.append(importedItem)
                }
            }

            removeItemsWithMissingParents(from: &items)
            compactSortOrder(in: &items)

            if !items.isEmpty {
                pages.append(LaunchPage(id: importedPage.id, sortIndex: pages.count, items: items))
            }
        }

        return ReconciledPages(pages: pages, skippedMissingAppNames: skippedMissingAppNames)
    }

    private static func mergedApplication(_ importedItem: LaunchItem, with localItem: LaunchItem) -> LaunchItem {
        var item = importedItem
        item.displayName = localItem.displayName
        item.subtitle = localItem.subtitle
        item.url = localItem.url
        item.bundleIdentifier = localItem.bundleIdentifier
        item.bundleName = localItem.bundleName
        item.localizedDisplayNames = localItem.localizedDisplayNames
        item.applicationCategory = localItem.applicationCategory
        item.version = localItem.version
        item.sourcePath = localItem.sourcePath
        return item
    }

    private static func removeItemsWithMissingParents(from items: inout [LaunchItem]) {
        let itemIDs = Set(items.map(\.id))
        for index in items.indices {
            if let parentID = items[index].parentID, !itemIDs.contains(parentID) {
                items[index].parentID = nil
            }
        }
    }

    private static func compactSortOrder(in items: inout [LaunchItem]) {
        let rootIDs = items
            .filter { !$0.isHidden && $0.parentID == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.id)

        for (sortIndex, id) in rootIDs.enumerated() {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].sortIndex = sortIndex
            }
        }

        let folderIDs = items
            .filter { $0.kind == .folder }
            .map(\.id)

        for folderID in folderIDs {
            let childIDs = items
                .filter { !$0.isHidden && $0.parentID == folderID }
                .sorted { $0.sortIndex < $1.sortIndex }
                .map(\.id)

            for (sortIndex, id) in childIDs.enumerated() {
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].sortIndex = sortIndex
                }
            }
        }
    }

    private static func boolValue(forKey key: String, defaultValue: Bool, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func doubleValue(forKey key: String, defaultValue: Double, defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.double(forKey: key)
    }

    private static func stringValue(forKey key: String, defaultValue: String, defaults: UserDefaults) -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    private static func validHotCorner(_ rawValue: String) -> KidoXHotCorner {
        KidoXHotCorner(rawValue: rawValue) ?? .none
    }

    private static func validDockIcon(_ rawValue: String) -> KidoXDockIcon {
        KidoXDockIcon(rawValue: rawValue) ?? .standard
    }

    private static func validLaunchSort(_ rawValue: String) -> KidoXLaunchSort {
        KidoXLaunchSort(rawValue: rawValue) ?? .default
    }

    private static func validBackgroundStyle(_ rawValue: String) -> KidoXBackgroundStyle {
        KidoXBackgroundStyle(storageValue: rawValue)
    }

    private static func validSolidPreset(_ rawValue: String) -> KidoXSolidBackgroundPreset {
        KidoXSolidBackgroundPreset(storageValue: rawValue)
    }
}

private extension UTType {
    static let kidoXBackup = UTType("com.clyapps.kidox.backup")
        ?? UTType(filenameExtension: "kidoxbackup", conformingTo: .json)
        ?? .json
}

private struct ProFeatureRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let showsPro: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22)
                .foregroundStyle(Color(nsColor: .systemPurple))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
            if showsPro {
                ProTag()
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ProTag: View {
    var body: some View {
        Text("Pro")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(Color(nsColor: .systemPurple))
            .background(Color(nsColor: .systemPurple).opacity(0.12), in: Capsule())
    }
}

// MARK: - Main Settings View (fallback/default)
struct SettingsView: View {
    @State private var state = SettingsState()

    var body: some View {
        HSplitView {
            SidebarView(state: state)
                .frame(minWidth: 200, maxWidth: 260)
            DetailView(state: state)
                .frame(minWidth: 400)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
