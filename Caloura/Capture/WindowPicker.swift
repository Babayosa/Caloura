import AppKit
import SwiftUI

struct WindowPickerView: View {
    let windows: [CaptureWindow]
    let onSelected: (CaptureWindow) -> Void
    let onCancelled: () -> Void

    @State private var hoveredWindowID: CGWindowID?

    var body: some View {
        VStack(spacing: 0) {
            Text("Click a window to capture")
                .font(.headline)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(windows) { window in
                        WindowRow(window: window, isHovered: hoveredWindowID == window.id)
                            .onTapGesture {
                                onSelected(window)
                            }
                            .onHover { isHovered in
                                hoveredWindowID = isHovered ? window.id : nil
                            }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 400)

            Divider()

            Button("Cancel") {
                onCancelled()
            }
            .keyboardShortcut(.cancelAction)
            .padding(8)
        }
        .frame(width: 340)
        .background(.regularMaterial)
    }
}

private struct WindowRow: View {
    let window: CaptureWindow
    let isHovered: Bool

    var body: some View {
        HStack {
            if !window.appName.isEmpty {
                Text(window.appName)
                    .fontWeight(.medium)
                Text(" - ")
                    .foregroundStyle(.secondary)
            }
            Text(window.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}


@MainActor
final class WindowPickerPanel {
    private var panel: NSPanel?

    func show(
        windows: [CaptureWindow],
        onSelected: @escaping (CaptureWindow) -> Void,
        onCancelled: @escaping () -> Void
    ) {
        let pickerView = WindowPickerView(
            windows: windows,
            onSelected: { [weak self] window in
                self?.panel?.close()
                self?.panel = nil
                onSelected(window)
            },
            onCancelled: { [weak self] in
                self?.panel?.close()
                self?.panel = nil
                onCancelled()
            }
        )

        let hostingView = NSHostingView(rootView: pickerView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 340, height: 500)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }
}
