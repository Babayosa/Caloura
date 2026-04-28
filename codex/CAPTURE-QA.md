# Capture QA Checklist

Run these checks before release when capture, overlay, cursor, Space, or
performance-sensitive code changes.

## Area Capture

- Trigger area capture from the menu bar while a normal desktop app is focused.
- Trigger area capture from a browser tab in full screen.
- Trigger area capture from TradingView in full screen.
- Trigger area capture from FaceTime in full screen.
- Confirm the overlay appears immediately and the cursor is a crosshair before dragging.
- Complete five area captures in a row without quitting Caloura.
- Start area capture, press ESC, then immediately start area capture again.
- Start area capture, switch Spaces, cancel, then start area capture again.

## Fullscreen Capture

- Trigger fullscreen capture on a single-display setup.
- Trigger fullscreen capture on a multi-display setup and select each display once.
- Trigger fullscreen capture immediately after an area capture.
- Cancel fullscreen display selection and confirm no overlay or crosshair remains.

## Guardrails

- Review unified logs for `capture_timeline_budget_violation`.
- `overlay_visible` should stay near-instant for area capture.
- `cursor_primed` should stay under one frame.
- Frozen screenshots must not delay initial overlay visibility.
- OCR, metadata, save, and clipboard work must not block selection UI.

## Required Automated Checks

- `swift build`
- `swiftlint lint --quiet`
- `swift test`
- Focused capture cursor/coordinator tests
- Xcode capture-system overlay checks
