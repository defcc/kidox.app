//
//  UninstallerView.swift
//  KidoXApp
//
//  Created by 程超 on 2026/6/25.
//

import AppKit
import SwiftUI

struct UninstallPanelSession: Identifiable, Equatable {
    enum Phase: Equatable {
        case planning
        case confirming(ApplicationUninstallPlan)
        case uninstalling(ApplicationUninstallPlan)
        case completed(ApplicationUninstallResult)
        case blockedForFree
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.planning, .planning):
                return true
            case (.confirming(let lhsPlan), .confirming(let rhsPlan)),
                 (.uninstalling(let lhsPlan), .uninstalling(let rhsPlan)):
                return lhsPlan.bundleIdentifier == rhsPlan.bundleIdentifier
                    && lhsPlan.appURL == rhsPlan.appURL
                    && lhsPlan.appByteCount == rhsPlan.appByteCount
                    && lhsPlan.dataTargets == rhsPlan.dataTargets
            case (.completed(let lhsResult), .completed(let rhsResult)):
                return lhsResult.bundleIdentifier == rhsResult.bundleIdentifier
                    && lhsResult.appURL == rhsResult.appURL
                    && lhsResult.appByteCount == rhsResult.appByteCount
                    && lhsResult.trashedAppURL == rhsResult.trashedAppURL
                    && lhsResult.removedDataTargets == rhsResult.removedDataTargets
                    && lhsResult.failedDataRemovals.map(\.url) == rhsResult.failedDataRemovals.map(\.url)
            case (.blockedForFree, .blockedForFree):
                return true
            case (.failed(let lhsMessage), .failed(let rhsMessage)):
                return lhsMessage == rhsMessage
            default:
                return false
            }
        }
    }

    let id = UUID()
    let item: LaunchItem
    var phase: Phase

    static func == (lhs: UninstallPanelSession, rhs: UninstallPanelSession) -> Bool {
        lhs.id == rhs.id
            && lhs.item.id == rhs.item.id
            && lhs.phase == rhs.phase
    }
}

struct UninstallCompletionAnimation: Identifiable, Equatable {
    let id = UUID()
    let item: LaunchItem
    let icon: NSImage
    let center: CGPoint
    let containerSize: CGSize
    let iconSize: CGFloat

    static func == (lhs: UninstallCompletionAnimation, rhs: UninstallCompletionAnimation) -> Bool {
        lhs.id == rhs.id
    }
}

struct UninstallPanelRouteView: NSViewRepresentable {
    let session: UninstallPanelSession
    let isPro: Bool
    let hasFullDiskAccess: Bool
    let anchor: CGPoint
    let onCancel: () -> Void
    let onConfirm: (LaunchItem, ApplicationUninstallPlan) async -> Bool
    let onRetryFailedItems: (ApplicationUninstallResult) async -> Bool
    let onOpenPrivacySettings: () -> Void
    let onRevealInFinder: (LaunchItem) -> Void
    let onUpgradeToPro: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(parent: self, in: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.closeFromSwiftUI()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var popover: NSPopover?
        private var hostingController: NSHostingController<UninstallPopoverContent>?
        private var representedSessionID: UUID?
        private var userDismissedSessionID: UUID?
        private var representedAnchor = CGPoint.zero
        private var isClosingFromSwiftUI = false
        private var onCancel: (() -> Void)?

        func update(parent: UninstallPanelRouteView, in view: NSView) {
            onCancel = parent.onCancel

            let content = UninstallPopoverContent(
                session: parent.session,
                isPro: parent.isPro,
                hasFullDiskAccess: parent.hasFullDiskAccess,
                onCancel: parent.onCancel,
                onConfirm: parent.onConfirm,
                onRetryFailedItems: parent.onRetryFailedItems,
                onOpenPrivacySettings: parent.onOpenPrivacySettings,
                onRevealInFinder: parent.onRevealInFinder,
                onUpgradeToPro: parent.onUpgradeToPro
            )

            if popover == nil {
                let hostingController = NSHostingController(rootView: content)
                if #available(macOS 13.0, *) {
                    hostingController.sizingOptions = [.preferredContentSize]
                }

                let popover = NSPopover()
                popover.behavior = .transient
                popover.animates = true
                popover.contentViewController = hostingController
                popover.delegate = self

                self.hostingController = hostingController
                self.popover = popover
            } else {
                hostingController?.rootView = content
            }

            updatePopoverSize()

            guard let popover else { return }
            let anchorChanged = distance(from: representedAnchor, to: parent.anchor) > 2
            let sessionChanged = representedSessionID != parent.session.id
            if sessionChanged {
                userDismissedSessionID = nil
            }
            representedSessionID = parent.session.id

            guard userDismissedSessionID != parent.session.id else {
                representedAnchor = parent.anchor
                return
            }

            if popover.isShown {
                if anchorChanged || sessionChanged {
                    isClosingFromSwiftUI = true
                    popover.close()
                    isClosingFromSwiftUI = false
                    showPopover(popover, from: view, anchor: parent.anchor)
                }
            } else {
                showPopover(popover, from: view, anchor: parent.anchor)
            }

            representedAnchor = parent.anchor
        }

        func closeFromSwiftUI() {
            isClosingFromSwiftUI = true
            popover?.close()
            isClosingFromSwiftUI = false
            popover = nil
            hostingController = nil
            representedSessionID = nil
            userDismissedSessionID = nil
        }

        func popoverDidClose(_ notification: Notification) {
            guard !isClosingFromSwiftUI else { return }
            userDismissedSessionID = representedSessionID
            onCancel?()
        }

        private func showPopover(_ popover: NSPopover, from view: NSView, anchor: CGPoint) {
            guard view.window != nil else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, let popover = self.popover else { return }
                    self.showPopover(popover, from: view, anchor: anchor)
                }
                return
            }

            popover.show(
                relativeTo: anchorRect(for: anchor, in: view),
                of: view,
                preferredEdge: .minY
            )
        }

        private func updatePopoverSize() {
            guard let popover, let hostingController else { return }
            hostingController.view.layoutSubtreeIfNeeded()
            let fittingSize = hostingController.view.fittingSize
            popover.contentSize = NSSize(
                width: max(420, fittingSize.width),
                height: max(180, fittingSize.height)
            )
        }

        private func anchorRect(for anchor: CGPoint, in view: NSView) -> NSRect {
            let side: CGFloat = 58
            let x = anchor.x - side / 2
            let y = view.bounds.height - anchor.y - side / 2
            return NSRect(x: x, y: y, width: side, height: side)
        }

        private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
            hypot(lhs.x - rhs.x, lhs.y - rhs.y)
        }
    }
}

private struct UninstallPopoverContent: View {
    let session: UninstallPanelSession
    let isPro: Bool
    let hasFullDiskAccess: Bool
    let onCancel: () -> Void
    let onConfirm: (LaunchItem, ApplicationUninstallPlan) async -> Bool
    let onRetryFailedItems: (ApplicationUninstallResult) async -> Bool
    let onOpenPrivacySettings: () -> Void
    let onRevealInFinder: (LaunchItem) -> Void
    let onUpgradeToPro: () -> Void

    var body: some View {
        Group {
            switch session.phase {
            case .planning:
                UninstallProgressPopover(
                    item: session.item,
                    title: KidoXL10n.format(.uninstallTitle, session.item.effectiveDisplayName),
                    message: KidoXL10n.string(.scanningRelatedAppData)
                )

            case .confirming(let plan):
                UninstallConfirmationPopover(
                    item: session.item,
                    plan: plan,
                    isPro: isPro,
                    hasFullDiskAccess: hasFullDiskAccess,
                    onCancel: onCancel,
                    onConfirm: {
                        await onConfirm(session.item, plan)
                    },
                    onOpenPrivacySettings: onOpenPrivacySettings,
                    onUpgradeToPro: onUpgradeToPro
                )

            case .uninstalling(let plan):
                UninstallProgressPopover(
                    item: session.item,
                    title: KidoXL10n.format(.uninstallTitle, session.item.effectiveDisplayName),
                    message: KidoXL10n.string(.uninstalling),
                    plan: plan
                )

            case .completed(let result):
                UninstallResultPopover(
                    item: session.item,
                    result: result,
                    hasFullDiskAccess: hasFullDiskAccess,
                    onDone: onCancel,
                    onRetryFailedItems: {
                        await onRetryFailedItems(result)
                    },
                    onOpenPrivacySettings: onOpenPrivacySettings
                )

            case .blockedForFree:
                FreeUninstallBlockedPopover(
                    item: session.item,
                    onRevealInFinder: {
                        onRevealInFinder(session.item)
                    },
                    onUpgradeToPro: onUpgradeToPro,
                    onDone: onCancel
                )

            case .failed(let message):
                UninstallFailurePopover(
                    item: session.item,
                    message: message,
                    onDone: onCancel
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct UninstallPoofAnimation: View {
    let animation: UninstallCompletionAnimation
    let onFinished: () -> Void

    @State private var didFinish = false

    var body: some View {
        NativePoofEffectView(animation: animation, onFinished: finishOnce)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishOnce() {
        guard !didFinish else { return }
        didFinish = true
        onFinished()
    }
}

private struct NativePoofEffectView: NSViewRepresentable {
    let animation: UninstallCompletionAnimation
    let onFinished: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FlippedPoofHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.animationID != animation.id else { return }
        context.coordinator.animationID = animation.id

        showWhenReady(in: nsView, attemptsRemaining: 6)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var animationID: UUID?
    }

    private func showWhenReady(in nsView: NSView, attemptsRemaining: Int) {
        DispatchQueue.main.async {
            nsView.layoutSubtreeIfNeeded()
            guard nsView.window != nil,
                  nsView.bounds.width > 1,
                  nsView.bounds.height > 1
            else {
                guard attemptsRemaining > 0 else {
                    onFinished()
                    return
                }
                showWhenReady(in: nsView, attemptsRemaining: attemptsRemaining - 1)
                return
            }

            let screenPoint = screenPoint(for: animation.center, in: nsView)
            AppKitPoofEffect.show(at: screenPoint, size: NSSize(width: animation.iconSize, height: animation.iconSize))

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                onFinished()
            }
        }
    }

    private func screenPoint(for point: CGPoint, in view: NSView) -> NSPoint {
        let localPoint = NSPoint(x: point.x, y: point.y)
        let windowPoint = view.convert(localPoint, to: nil)
        return view.window?.convertPoint(toScreen: windowPoint) ?? windowPoint
    }

    private final class FlippedPoofHostView: NSView {
        override var isFlipped: Bool { true }
    }
}

private enum AppKitPoofEffect {
    private typealias ShowAnimationEffect = @convention(c) (
        Int32,
        NSPoint,
        NSSize,
        UnsafeRawPointer?,
        UnsafeRawPointer?,
        UnsafeRawPointer?
    ) -> Void

    static func show(at point: NSPoint, size: NSSize) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSShowAnimationEffect") else { return }
        let show = unsafeBitCast(symbol, to: ShowAnimationEffect.self)
        show(10, point, size, nil, nil, nil)
    }
}

private struct UninstallConfirmationPopover: View {
    let item: LaunchItem
    let plan: ApplicationUninstallPlan
    let isPro: Bool
    let hasFullDiskAccess: Bool
    let onCancel: () -> Void
    let onConfirm: () async -> Bool
    let onOpenPrivacySettings: () -> Void
    let onUpgradeToPro: () -> Void

    @State private var showsDetails = false
    @State private var isConfirming = false

    var body: some View {
        UninstallPopoverChrome {
            VStack(spacing: 14) {
                UninstallHeader(
                    item: item,
                    title: KidoXL10n.format(.uninstallQuestionTitle, item.effectiveDisplayName),
                    subtitle: KidoXL10n.string(.uninstallDescription),
                    accessory: nil
                )

                UninstallMetricsRow(metrics: [
                    .init(symbol: "folder", title: KidoXL10n.string(.appData), value: formattedByteCount(plan.dataByteCount)),
                    .init(symbol: "app", title: KidoXL10n.string(.app), value: formattedByteCount(plan.appByteCount)),
                    .init(symbol: "sum", title: KidoXL10n.string(.total), value: formattedByteCount(plan.totalRecoverableByteCount))
                ])

                if shouldShowPermissionNotice {
                    UninstallPermissionNotice(onOpenPrivacySettings: onOpenPrivacySettings)
                }

                if !isPro {
                    UninstallUpgradeNotice(onUpgradeToPro: onUpgradeToPro)
                }

                UninstallDetailsSection(
                    isExpanded: $showsDetails,
                    collapsedTitle: KidoXL10n.uiFormat("%d related items", displayTargets.count),
                    expandedTitle: KidoXL10n.string(.items),
                    trailingText: KidoXL10n.uiFormat("%d data locations", plan.dataTargets.count)
                ) {
                    UninstallTargetList(
                        targets: displayTargets,
                        showsPermissionBadges: !hasFullDiskAccess
                    )
                    .frame(maxHeight: 240)
                }

                HStack(spacing: 10) {
                    Button(KidoXL10n.string(.cancel), action: onCancel)
                        .buttonStyle(UninstallSecondaryButtonStyle())
                        .disabled(isConfirming)

                    Spacer()

                    Button {
                        guard !isConfirming else { return }
                        isConfirming = true
                        Task { @MainActor in
                            _ = await onConfirm()
                            isConfirming = false
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if isConfirming {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.72)
                            }
                            Text(isConfirming ? KidoXL10n.string(.uninstalling) : KidoXL10n.string(.uninstall))
                        }
                    }
                    .buttonStyle(UninstallDestructiveButtonStyle())
                    .disabled(isConfirming)
                }
            }
        }
    }

    private var displayTargets: [UninstallDisplayTarget] {
        [.app(item: item, url: plan.appURL, byteCount: plan.appByteCount)]
            + plan.dataTargets.map { .data($0) }
    }

    private var shouldShowPermissionNotice: Bool {
        !hasFullDiskAccess && plan.dataTargets.contains { $0.requiresFullDiskAccess }
    }
}

private struct UninstallProgressPopover: View {
    let item: LaunchItem
    let title: String
    let message: String
    var plan: ApplicationUninstallPlan?

    var body: some View {
        UninstallPopoverChrome {
            VStack(spacing: 16) {
                UninstallHeader(
                    item: item,
                    title: title,
                    subtitle: message,
                    accessory: nil
                )

                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 4)

                if let plan {
                    UninstallMetricsRow(metrics: [
                        .init(symbol: "folder", title: KidoXL10n.string(.appData), value: formattedByteCount(plan.dataByteCount)),
                        .init(symbol: "app", title: KidoXL10n.string(.app), value: formattedByteCount(plan.appByteCount))
                    ])
                }
            }
        }
    }
}

private struct UninstallResultPopover: View {
    let item: LaunchItem
    let result: ApplicationUninstallResult
    let hasFullDiskAccess: Bool
    let onDone: () -> Void
    let onRetryFailedItems: () async -> Bool
    let onOpenPrivacySettings: () -> Void

    @State private var showsDetails = false
    @State private var isRetrying = false

    var body: some View {
        UninstallPopoverChrome {
            VStack(spacing: 14) {
                UninstallHeader(
                    item: item,
                    title: result.hasDataRemovalFailures
                        ? KidoXL10n.string(.uninstalledWithIssues)
                        : KidoXL10n.format(.uninstalledTitle, item.effectiveDisplayName),
                    subtitle: result.hasDataRemovalFailures
                        ? KidoXL10n.string(.uninstalledIssuesDescription)
                        : KidoXL10n.string(.uninstalledSuccessDescription),
                    accessory: result.hasDataRemovalFailures ? AnyView(warningIcon) : AnyView(successIcon)
                )

                UninstallMetricsRow(metrics: [
                    .init(symbol: "folder", title: KidoXL10n.string(.appData), value: formattedByteCount(result.removedDataByteCount)),
                    .init(symbol: "app", title: KidoXL10n.string(.app), value: formattedByteCount(result.appByteCount))
                ])

                if result.hasDataRemovalFailures {
                    if !hasFullDiskAccess && result.failedDataRemovals.contains(where: { $0.target.requiresFullDiskAccess }) {
                        UninstallPermissionNotice(onOpenPrivacySettings: onOpenPrivacySettings)
                    }

                    UninstallDetailsSection(
                        isExpanded: $showsDetails,
                        collapsedTitle: KidoXL10n.uiFormat("%d failed removals", result.failedDataRemovals.count),
                        expandedTitle: KidoXL10n.string(.failedRemovals),
                        trailingText: nil
                    ) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(result.failedDataRemovals, id: \.url) { failure in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(failure.url.path)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .foregroundStyle(.primary)

                                        Text(failure.errorDescription)
                                            .font(.system(size: 11))
                                            .lineLimit(2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        }
                        .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxHeight: 150)
                    }
                }

                HStack(spacing: 10) {
                    if result.hasDataRemovalFailures {
                        Button(KidoXL10n.string(.openPrivacySettings), action: onOpenPrivacySettings)
                            .buttonStyle(UninstallSecondaryButtonStyle())

                        Button {
                            guard !isRetrying else { return }
                            isRetrying = true
                            Task { @MainActor in
                                _ = await onRetryFailedItems()
                                isRetrying = false
                            }
                        } label: {
                            HStack(spacing: 7) {
                                if isRetrying {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.72)
                                }
                                Text(isRetrying ? KidoXL10n.string(.retrying) : KidoXL10n.string(.retryFailedItems))
                            }
                        }
                        .buttonStyle(UninstallSecondaryButtonStyle())
                        .disabled(isRetrying)
                    }

                    Spacer()

                    Button(KidoXL10n.string(.done), action: onDone)
                        .buttonStyle(UninstallSecondaryButtonStyle())
                }
            }
        }
    }

    private var warningIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(width: 36, height: 36)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var successIcon: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(.green)
            .frame(width: 36, height: 36)
            .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct FreeUninstallBlockedPopover: View {
    let item: LaunchItem
    let onRevealInFinder: () -> Void
    let onUpgradeToPro: () -> Void
    let onDone: () -> Void

    var body: some View {
        UninstallPopoverChrome {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: IconCache.rasterizedIcon(for: item.sourcePath, pointSize: 44))
                        .frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(KidoXL10n.ui("Administrator permission required"))
                            .font(.system(size: 20, weight: .semibold))
                            .lineLimit(2)
                            .foregroundStyle(.primary)

                        Text(KidoXL10n.ui("KidoX Free cannot remove this app directly."))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                    }

                    Spacer(minLength: 8)

                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 36, height: 36)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(KidoXL10n.ui("Choose an option:"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Button(action: onUpgradeToPro) {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(KidoXL10n.ui("Upgrade to Pro"))
                                    .font(.system(size: 13, weight: .semibold))
                                Text(KidoXL10n.ui("Remove protected apps from KidoX."))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.82))
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(UninstallPrimaryRowButtonStyle())

                    Button(action: onRevealInFinder) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(KidoXL10n.string(.showInFinder))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(KidoXL10n.ui("Delete it manually in Finder."))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(UninstallOptionRowButtonStyle())
                }

                HStack {
                    Spacer()
                    Button(KidoXL10n.string(.done), action: onDone)
                        .buttonStyle(UninstallSecondaryButtonStyle())
                }
            }
        }
    }
}

private struct UninstallPrimaryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 13)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.82) : Color.accentColor)
            )
            .foregroundStyle(.white)
    }
}

private struct UninstallOptionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 13)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? .black.opacity(0.10) : .black.opacity(0.045))
            )
    }
}

private struct UninstallFailurePopover: View {
    let item: LaunchItem
    let message: String
    let onDone: () -> Void

    var body: some View {
        UninstallPopoverChrome {
            VStack(spacing: 14) {
                UninstallHeader(
                    item: item,
                    title: KidoXL10n.format(.unableToUninstall, item.effectiveDisplayName),
                    subtitle: message,
                    accessory: AnyView(
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 36, height: 36)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    )
                )

                HStack {
                    Spacer()
                    Button(KidoXL10n.string(.done), action: onDone)
                        .buttonStyle(UninstallSecondaryButtonStyle())
                }
            }
        }
    }
}

private struct UninstallPopoverChrome<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(18)
        }
        .frame(width: 420)
    }
}

private struct UninstallHeader: View {
    let item: LaunchItem
    let title: String
    let subtitle: String
    let accessory: AnyView?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: IconCache.rasterizedIcon(for: item.sourcePath, pointSize: 44))
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

            }

            Spacer(minLength: 8)

            if let accessory {
                accessory
            }
        }
    }
}

private struct UninstallMetricsRow: View {
    let metrics: [UninstallMetric]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(metrics) { metric in
                HStack(spacing: 9) {
                    Image(systemName: metric.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(metric.value)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

private struct UninstallMetric: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let value: String
}

private struct UninstallPermissionNotice: View {
    let onOpenPrivacySettings: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(KidoXL10n.string(.mayRequireAppDataPermission))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(KidoXL10n.string(.grantPermission), action: onOpenPrivacySettings)
                .buttonStyle(UninstallInlineButtonStyle())
        }
        .padding(9)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.orange.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct UninstallUpgradeNotice: View {
    let onUpgradeToPro: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(KidoXL10n.ui("Deep cleanup is a Pro feature"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(KidoXL10n.ui("Free removes the app only. Pro can remove related app data."))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(KidoXL10n.ui("Upgrade"), action: onUpgradeToPro)
                .buttonStyle(UninstallInlineButtonStyle())
        }
        .padding(9)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.blue.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct UninstallDetailsSection<Content: View>: View {
    @Binding var isExpanded: Bool
    let collapsedTitle: String
    let expandedTitle: String
    let trailingText: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Text(isExpanded ? expandedTitle : collapsedTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let trailingText, isExpanded {
                    Spacer(minLength: 8)
                    Text(trailingText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Spacer(minLength: 8)
                }

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? KidoXL10n.ui("Hide Details") : KidoXL10n.ui("Details"))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(UninstallInlineButtonStyle())
            }

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct UninstallTargetList: View {
    let targets: [UninstallDisplayTarget]
    let showsPermissionBadges: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(targets) { target in
                    UninstallTargetRow(
                        target: target,
                        showsPermissionBadge: showsPermissionBadges && target.requiresFullDiskAccess
                    )

                    if target.id != targets.last?.id {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
        }
        .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct UninstallTargetRow: View {
    let target: UninstallDisplayTarget
    let showsPermissionBadge: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(target.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if showsPermissionBadge {
                        Text(KidoXL10n.string(.requiresPermission))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }

                Text(target.url.path)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(formattedByteCount(target.byteCount))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var icon: some View {
        switch target {
        case .app(let item, _, _):
            Image(nsImage: IconCache.rasterizedIcon(for: item.sourcePath, pointSize: 22))
                .frame(width: 22, height: 22)
        case .data:
            Image(systemName: "folder")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private enum UninstallDisplayTarget: Identifiable {
    case app(item: LaunchItem, url: URL, byteCount: Int64)
    case data(ApplicationUninstallTarget)

    var id: String {
        url.path
    }

    var title: String {
        switch self {
        case .app(let item, _, _):
            item.effectiveDisplayName
        case .data(let target):
            target.url.deletingPathExtension().lastPathComponent
        }
    }

    var url: URL {
        switch self {
        case .app(_, let url, _):
            url
        case .data(let target):
            target.url
        }
    }

    var byteCount: Int64 {
        switch self {
        case .app(_, _, let byteCount):
            byteCount
        case .data(let target):
            target.byteCount
        }
    }

    var requiresFullDiskAccess: Bool {
        switch self {
        case .app:
            false
        case .data(let target):
            target.requiresFullDiskAccess
        }
    }
}

private struct UninstallSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? .black.opacity(0.10) : .black.opacity(0.055))
            )
    }
}

private struct UninstallPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.82) : Color.accentColor)
            )
    }
}

private struct UninstallDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Color.red.opacity(0.82) : Color.red)
            )
    }
}

private struct UninstallInlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? .black.opacity(0.10) : .black.opacity(0.055))
            )
    }
}

private extension ApplicationUninstallTarget {
    var requiresFullDiskAccess: Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Containers/")
            || path.contains("/Library/Group Containers/")
            || path.contains("/Library/Application Scripts/")
            || path.contains("/Library/Mail/")
            || path.contains("/Library/Messages/")
            || path.contains("/Library/Safari/")
    }
}

private func formattedByteCount(_ byteCount: Int64) -> String {
    if byteCount <= 0 {
        return KidoXL10n.ui("Zero KB")
    }
    return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
}
