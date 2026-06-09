import SwiftUI
import AppKit

// MARK: - Coordinate Transform (view-space → image-space)

struct AnnotationCoordTransform {
    let imageSize: CGSize
    let canvasSize: CGSize

    var imageFrame: CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let imageAspect = imageSize.width / imageSize.height
        let canvasAspect = canvasSize.width / canvasSize.height

        if imageAspect > canvasAspect {
            let fittedWidth = canvasSize.width
            let fittedHeight = fittedWidth / imageAspect
            return CGRect(
                x: 0,
                y: (canvasSize.height - fittedHeight) / 2,
                width: fittedWidth,
                height: fittedHeight
            )
        } else {
            let fittedHeight = canvasSize.height
            let fittedWidth = fittedHeight * imageAspect
            return CGRect(
                x: (canvasSize.width - fittedWidth) / 2,
                y: 0,
                width: fittedWidth,
                height: fittedHeight
            )
        }
    }

    var scale: CGFloat {
        let frame = imageFrame
        guard frame.width > 0 else { return 1 }
        return imageSize.width / frame.width
    }

    func viewToImage(_ point: CGPoint) -> CGPoint {
        let frame = imageFrame
        guard frame.width > 0, frame.height > 0 else { return point }
        return CGPoint(
            x: (point.x - frame.origin.x) * (imageSize.width / frame.width),
            y: (point.y - frame.origin.y) * (imageSize.height / frame.height)
        )
    }
}

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

private enum AnnotationOverlayDrawing {
    static let lineWidth: CGFloat = 3
    static let arrowLength: CGFloat = 15
    static let highlightOpacity: CGFloat = 0.3
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
    @State private var canvasSize: CGSize = .zero

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
                    .help(tool.rawValue)
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
                    .keyboardShortcut(.cancelAction)
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
                .background(
                    Color.clear.preference(key: CanvasSizeKey.self, value: geometry.size)
                )
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
                                if undoStack.count >= 30 { undoStack.removeFirst() }
                                undoStack.append(annotations)
                                redoStack.removeAll()
                                annotations.append(annotation)
                                currentAnnotation = nil
                            }
                        }
                )
            }
            .onPreferenceChange(CanvasSizeKey.self) { canvasSize = $0 }
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
        let size = image.size
        let transform = AnnotationCoordTransform(imageSize: size, canvasSize: canvasSize)
        let lineScale = transform.scale

        // flipped: true matches SwiftUI's top-left origin coordinate system
        let annotatedImage = NSImage(size: size, flipped: true) { rect in
            self.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

            for annotation in self.annotations {
                let start = transform.viewToImage(annotation.startPoint)
                let end = transform.viewToImage(annotation.endPoint)
                self.drawAnnotation(annotation.tool, start: start, end: end,
                                    color: NSColor(annotation.color), lineScale: lineScale)
            }
            return true
        }

        onSave(annotatedImage)
    }

    private func drawAnnotation(_ tool: AnnotationTool, start: CGPoint, end: CGPoint,
                                color: NSColor, lineScale: CGFloat) {
        let lineWidth = AnnotationOverlayDrawing.lineWidth * lineScale

        switch tool {
        case .arrow:
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.move(to: start)
            path.line(to: end)
            path.stroke()

            let arrowLength = AnnotationOverlayDrawing.arrowLength * lineScale
            let angle = atan2(end.y - start.y, end.x - start.x)
            let p1 = CGPoint(
                x: end.x - arrowLength * cos(angle - .pi / 6),
                y: end.y - arrowLength * sin(angle - .pi / 6)
            )
            let p2 = CGPoint(
                x: end.x - arrowLength * cos(angle + .pi / 6),
                y: end.y - arrowLength * sin(angle + .pi / 6)
            )
            color.setFill()
            let arrowPath = NSBezierPath()
            arrowPath.move(to: end)
            arrowPath.line(to: p1)
            arrowPath.line(to: p2)
            arrowPath.close()
            arrowPath.fill()

        case .rectangle:
            color.setStroke()
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.stroke()

        case .highlight:
            color.withAlphaComponent(AnnotationOverlayDrawing.highlightOpacity).setFill()
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            NSBezierPath(rect: rect).fill()
        }
    }
}

// MARK: - Preference Key

private struct CanvasSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Annotation Shape

struct AnnotationShape: View {
    let annotation: Annotation

    var body: some View {
        switch annotation.tool {
        case .arrow:
            // Shaft (stroked line)
            Path { path in
                path.move(to: annotation.startPoint)
                path.addLine(to: annotation.endPoint)
            }
            .stroke(annotation.color, lineWidth: AnnotationOverlayDrawing.lineWidth)
            // Arrowhead (filled triangle — matches save path rendering)
            ArrowHeadShape(end: annotation.endPoint,
                           angle: atan2(annotation.endPoint.y - annotation.startPoint.y,
                                        annotation.endPoint.x - annotation.startPoint.x))
                .fill(annotation.color)

        case .rectangle:
            Rectangle()
                .stroke(annotation.color, lineWidth: AnnotationOverlayDrawing.lineWidth)
                .frame(width: annotation.rect.width, height: annotation.rect.height)
                .position(x: annotation.rect.midX, y: annotation.rect.midY)

        case .highlight:
            Rectangle()
                .fill(annotation.color.opacity(Double(AnnotationOverlayDrawing.highlightOpacity)))
                .frame(width: annotation.rect.width, height: annotation.rect.height)
                .position(x: annotation.rect.midX, y: annotation.rect.midY)
        }
    }
}

struct ArrowHeadShape: Shape {
    let end: CGPoint
    let angle: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            let p1 = CGPoint(
                x: end.x - AnnotationOverlayDrawing.arrowLength * cos(angle - .pi / 6),
                y: end.y - AnnotationOverlayDrawing.arrowLength * sin(angle - .pi / 6)
            )
            let p2 = CGPoint(
                x: end.x - AnnotationOverlayDrawing.arrowLength * cos(angle + .pi / 6),
                y: end.y - AnnotationOverlayDrawing.arrowLength * sin(angle + .pi / 6)
            )
            path.move(to: end)
            path.addLine(to: p1)
            path.addLine(to: p2)
            path.closeSubpath()
        }
    }
}

// MARK: - Annotation Window Controller

@MainActor
final class AnnotationWindowController {
    private let presenter = SingleWindowPresenter<AnnotationOverlayView>()

    func show(image: NSImage, onSave: @escaping (NSImage) -> Void) {
        let imageSize = image.size
        let maxDimension: CGFloat = 800
        let scale = min(
            maxDimension / imageSize.width,
            maxDimension / imageSize.height,
            1.0
        )
        let windowSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale + 44 // toolbar height
        )

        let config = SingleWindowPresenter<AnnotationOverlayView>.WindowConfig(
            title: "Annotate Screenshot",
            size: windowSize,
            styleMask: [.titled, .closable, .resizable]
        )
        presenter.show(config: config, activateApp: true) {
            AnnotationOverlayView(
                image: image,
                onSave: { [weak self] annotatedImage in
                    self?.presenter.close()
                    onSave(annotatedImage)
                },
                onCancel: { [weak self] in
                    self?.presenter.close()
                }
            )
        }
    }
}
