import AppKit

enum UITestLaunchContext {
    static let isEnabled = ProcessInfo.processInfo.environment["CALOURA_UI_TEST_HOST"] == "1"
}

@MainActor
final class UITestHostWindowController: NSWindowController {
    static let shared = UITestHostWindowController()

    private let performanceRecorder = CapturePerformanceRecorder.shared
    private let cursorController = CaptureCursorController()
    private let onboardingController = OnboardingWindowController()
    private var areaSession: AreaCaptureSessionCoordinator?
    private var fullscreenSession: FullscreenCaptureSessionCoordinator?

    private let stateLabel = NSTextField(labelWithString: "idle")
    private let detailLabel = NSTextField(labelWithString: "Ready")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Caloura UI Test Host"
        window.identifier = NSUserInterfaceItemIdentifier("ui-test-host-window")
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])

        let titleLabel = NSTextField(labelWithString: "Caloura UI Test Host")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        stateLabel.font = .systemFont(ofSize: 14, weight: .medium)
        stateLabel.identifier = NSUserInterfaceItemIdentifier("ui-test-state")
        stateLabel.setAccessibilityIdentifier("ui-test-state")
        stack.addArrangedSubview(stateLabel)

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.identifier = NSUserInterfaceItemIdentifier("ui-test-detail")
        detailLabel.setAccessibilityIdentifier("ui-test-detail")
        stack.addArrangedSubview(detailLabel)

        let areaButton = Self.makeButton(
            "Area Overlay",
            id: "ui-test-show-area",
            action: #selector(showAreaCapture)
        )
        let fullscreenButton = Self.makeButton(
            "Fullscreen Overlay",
            id: "ui-test-show-fullscreen",
            action: #selector(showFullscreenCapture)
        )
        let windowButton = Self.makeButton(
            "Window Picker",
            id: "ui-test-show-window",
            action: #selector(showWindowPicker)
        )
        let quickAccessButton = Self.makeButton(
            "Quick Access",
            id: "ui-test-show-quick-access",
            action: #selector(showQuickAccess)
        )
        let permissionRepairButton = Self.makeButton(
            "Permission Repair",
            id: "ui-test-show-permission-repair",
            action: #selector(showPermissionRepair)
        )
        let resetButton = Self.makeButton(
            "Reset",
            id: "ui-test-reset",
            action: #selector(resetHost)
        )

        stack.addArrangedSubview(Self.buttonRow(
            areaButton,
            fullscreenButton
        ))
        stack.addArrangedSubview(Self.buttonRow(
            windowButton,
            quickAccessButton
        ))
        stack.addArrangedSubview(Self.buttonRow(
            permissionRepairButton,
            resetButton
        ))

        super.init(window: window)

        [
            areaButton,
            fullscreenButton,
            windowButton,
            quickAccessButton,
            permissionRepairButton,
            resetButton
        ].forEach { button in
            button.target = self
        }

        reset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reset()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    @objc private func resetHost() {
        reset()
    }

    private func reset() {
        areaSession?.dismiss()
        areaSession = nil
        fullscreenSession?.dismiss()
        fullscreenSession = nil
        QuickAccessOverlay.shared.dismiss()
        onboardingController.close()
        updateState("idle", detail: "Ready")
    }

    @objc private func showAreaCapture() {
        areaSession?.dismiss()
        let session = performanceRecorder.beginSession(mode: .area)
        let coordinator = AreaCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            cursorController: cursorController,
            onSelection: { [weak self] _, _, _ in
                self?.updateState("area-selection-completed", detail: RegionSelectionView.hintText)
            },
            onCancel: { [weak self] in
                self?.updateState("area-cancelled", detail: RegionSelectionView.hintText)
            }
        )
        coordinator.present()
        areaSession = coordinator
        updateState("area-overlay-visible", detail: RegionSelectionView.hintText)
    }

    @objc private func showFullscreenCapture() {
        fullscreenSession?.dismiss()
        let session = performanceRecorder.beginSession(mode: .fullscreen)
        let coordinator = FullscreenCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            cursorController: cursorController,
            onSelection: { [weak self] _ in
                self?.updateState(
                    "fullscreen-selection-completed",
                    detail: ScreenSelectionView.captureHintText
                )
            },
            onCancel: { [weak self] in
                self?.updateState(
                    "fullscreen-cancelled",
                    detail: ScreenSelectionView.captureHintText
                )
            }
        )
        coordinator.present()
        fullscreenSession = coordinator
        updateState("fullscreen-overlay-visible", detail: ScreenSelectionView.captureHintText)
    }

    @objc private func showWindowPicker() {
        let session = performanceRecorder.beginSession(mode: .window)
        let coordinator = WindowCaptureSessionCoordinator(
            session: session,
            performanceRecorder: performanceRecorder,
            hasWarmContent: true,
            prewarmContent: { },
            pickWindow: { onPresented in
                onPresented()
                return .cancelled
            }
        )
        Task { @MainActor [weak self] in
            _ = await coordinator.pick()
            self?.updateState("window-picker-visible", detail: "Picker presentation hook fired")
        }
    }

    @objc private func showQuickAccess() {
        let image = makePreviewImage(width: 160, height: 110)
        let screenshot = ProcessedScreenshot(
            image: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            ),
            cgImage: image,
            context: CaptureContext(mode: .area)
        )
        QuickAccessOverlay.shared.show(for: screenshot)
        updateState("quick-access-visible", detail: "Compact 4 + More overlay presented")
    }

    @objc private func showPermissionRepair() {
        onboardingController.show(
            settings: AppSettings.shared,
            initialState: .grantScreenRecording
        )
        updateState("permission-repair-visible", detail: "Onboarding repair window opened")
    }

    private func updateState(_ state: String, detail: String) {
        stateLabel.stringValue = state
        detailLabel.stringValue = detail
    }

    private static func buttonRow(_ left: NSButton, _ right: NSButton) -> NSStackView {
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private static func makeButton(_ title: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityIdentifier(id)
        button.bezelStyle = .rounded
        return button
    }

    private func makePreviewImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return Self.fallbackImage
        }

        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 12, y: 12, width: width - 24, height: height - 24))

        guard let image = context.makeImage() else {
            return Self.fallbackImage
        }
        return image
    }

    private static let fallbackImage: CGImage = {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        )!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return ctx.makeImage()!
    }()
}
