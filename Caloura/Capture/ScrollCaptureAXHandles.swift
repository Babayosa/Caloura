import AppKit

struct AXElementHandle: @unchecked Sendable {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    init?(attributeValue: AnyObject?) {
        guard let attributeValue,
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }

        self.element = unsafeBitCast(attributeValue, to: AXUIElement.self)
    }
}

struct AXValueHandle: @unchecked Sendable {
    let value: AXValue

    init?(attributeValue: AnyObject?) {
        guard let attributeValue,
              CFGetTypeID(attributeValue) == AXValueGetTypeID() else {
            return nil
        }

        self.value = unsafeBitCast(attributeValue, to: AXValue.self)
    }

    func cgPoint() -> CGPoint? {
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    func cgSize() -> CGSize? {
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }
        return size
    }
}
