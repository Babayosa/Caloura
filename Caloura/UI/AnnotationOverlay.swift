import SwiftUI
import AppKit

// MARK: - Annotation Types

enum AnnotationTool: String, CaseIterable {
    case arrow = "Arrow"
    case rectangle = "Rectangle"
    case highlight = "Highlight"

    var systemImage: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .highlight: return "highlighter"
        }
    }
}

struct Annotation: Identifiable {
    let id = UUID()
    let tool: AnnotationTool
    var startPoint: CGPoint
    var endPoint: CGPoint
    var color: Color

    var rect: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }
}

// MARK: - Annotation Overlay View

struct AnnotationOverlayView: View {
    let image: NSImage
    let onSave: (NSImage) -> Void
    let onCancel: () -> Void

    @State private var selectedTool: AnnotationTool = .arrow
    @State private var selectedColor: Color = .red
    @State private var annotations: [Annotation] = []
    @State private var currentAnnotation: Annotation?
    @State private var undoStack: [[Annotation]] = []
    @State private var redoStack: [[Annotation]] = []

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button {
                        selectedTool = tool
                    } label: {
                        Image(systemName: tool.systemImage)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedTool == tool ? .accentColor : .secondary)
                }

                Divider()
                    .frame(height: 20)

                ColorPicker("", selection: $selectedColor)
                    .labelsHidden()
                    .frame(width: 30)

                Divider()
                    .frame(height: 20)

                Button {
                    undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .disabled(annotations.isEmpty)
                .keyboardShortcut("z", modifiers: .command)

                Button {
                    redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .disabled(redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Spacer()

                Button("Cancel") { onCancel() }
                Button("Save") { saveAnnotatedImage() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(8)
            .background(.regularMaterial)

            // Canvas
            GeometryReader { geometry in
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)

                    // Draw completed annotations
                    ForEach(annotations) { annotation in
                        AnnotationShape(annotation: annotation)
                    }

                    // Draw current annotation
                    if let current = currentAnnotation {
                        AnnotationShape(annotation: current)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if currentAnnotation == nil {
                                currentAnnotation = Annotation(
                                    tool: selectedTool,
                                    startPoint: value.startLocation,
                                    endPoint: value.location,
                                    color: selectedColor
                                )
                            } else {
                                currentAnnotation?.endPoint = value.location
                            }
                        }
                        .onEnded { _ in
                            if let annotation = currentAnnotation {
                                undoStack.append(annotations)
                                redoStack.removeAll()
                                annotations.append(annotation)
                                currentAnnotation = nil
                            }
                        }
                )
            }
        }
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    private func saveAnnotatedImage() {
        // Render annotations onto image
        let size = image.size
        let annotatedImage = NSImage(size: size, flipped: false) { rect in
            self.image.draw(in: rect)

            // Draw annotations
            for annotation in self.annotations {
                self.drawAnnotation(annotation, in: rect, imageSize: size)
            }
            return true
        }

        onSave(annotatedImage)
    }

    private func drawAnnotation(_ annotation: Annotation, in canvasRect: CGRect, imageSize: NSSize) {
        let nsColor = NSColor(annotation.color)

        switch annotation.tool {
        case .arrow:
            nsColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 3
            path.move(to: annotation.startPoint)
            path.line(to: annotation.endPoint)
            path.stroke()

            // Arrowhead
            drawArrowhead(from: annotation.startPoint, to: annotation.endPoint, color: nsColor)

        case .rectangle:
            nsColor.setStroke()
            let path = NSBezierPath(rect: annotation.rect)
            path.lineWidth = 3
            path.stroke()

        case .highlight:
            nsColor.withAlphaComponent(0.3).setFill()
            let path = NSBezierPath(rect: annotation.rect)
            path.fill()
        }
    }

    private func drawArrowhead(from start: CGPoint, to end: CGPoint, color: NSColor) {
        let length: CGFloat = 15
        let angle = atan2(end.y - start.y, end.x - start.x)

        let p1 = CGPoint(
            x: end.x - length * cos(angle - .pi / 6),
            y: end.y - length * sin(angle - .pi / 6)
        )
        let p2 = CGPoint(
            x: end.x - length * cos(angle + .pi / 6),
            y: end.y - length * sin(angle + .pi / 6)
        )

        color.setFill()
        let path = NSBezierPath()
        path.move(to: end)
        path.line(to: p1)
        path.line(to: p2)
        path.close()
        path.fill()
    }
}

// MARK: - Annotation Shape

struct AnnotationShape: View {
    let annotation: Annotation

    var body: some View {
        switch annotation.tool {
        case .arrow:
            ArrowShape(start: annotation.startPoint, end: annotation.endPoint)
                .stroke(annotation.color, lineWidth: 3)

        case .rectangle:
            Rectangle()
                .stroke(annotation.color, lineWidth: 3)
                .frame(width: annotation.rect.width, height: annotation.rect.height)
                .position(x: annotation.rect.midX, y: annotation.rect.midY)

        case .highlight:
            Rectangle()
                .fill(annotation.color.opacity(0.3))
                .frame(width: annotation.rect.width, height: annotation.rect.height)
                .position(x: annotation.rect.midX, y: annotation.rect.midY)
        }
    }
}

struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)

            // Arrowhead
            let length: CGFloat = 15
            let angle = atan2(end.y - start.y, end.x - start.x)

            let p1 = CGPoint(
                x: end.x - length * cos(angle - .pi / 6),
                y: end.y - length * sin(angle - .pi / 6)
            )
            let p2 = CGPoint(
                x: end.x - length * cos(angle + .pi / 6),
                y: end.y - length * sin(angle + .pi / 6)
            )

            path.move(to: end)
            path.addLine(to: p1)
            path.move(to: end)
            path.addLine(to: p2)
        }
    }
}

// MARK: - Annotation Window Controller

@MainActor
final class AnnotationWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(image: NSImage, onSave: @escaping (NSImage) -> Void) {
        let annotationView = AnnotationOverlayView(
            image: image,
            onSave: { [weak self] annotatedImage in
                self?.window?.close()
                self?.window = nil
                onSave(annotatedImage)
            },
            onCancel: { [weak self] in
                self?.window?.close()
                self?.window = nil
            }
        )

        let hostingView = NSHostingView(rootView: annotationView)
        let imageSize = image.size
        let maxDimension: CGFloat = 800
        let scale = min(maxDimension / imageSize.width, maxDimension / imageSize.height, 1.0)
        let windowSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale + 44 // toolbar height
        )
        hostingView.frame = CGRect(origin: .zero, size: windowSize)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "Annotate Screenshot"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // Clean up when user closes via title bar to prevent window/view leak
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            let closingWindow = notification.object as? NSWindow
            Task { @MainActor in
                guard self?.window === closingWindow else { return }
                self?.window = nil
                if let token = self?.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self?.closeObserver = nil
                }
            }
        }

        self.window = window
    }
}
