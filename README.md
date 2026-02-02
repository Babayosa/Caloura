# Caloura

A fast, lightweight macOS menu-bar screenshot tool for students, educators, and knowledge workers.

<!-- TODO: Add screenshot here -->

## Features

- **Three capture modes**: area selection, window picker, full screen (with multi-display support)
- **Smart crop**: automatic whitespace trimming via Vision saliency detection
- **Background OCR**: text recognition on every capture
- **Annotations**: arrows, rectangles, highlights with undo
- **Multi-format clipboard**: image, Markdown, citation, or all at once
- **Pinned screenshots**: floating always-on-top windows for reference
- **Delayed capture**: 3-second countdown with ESC cancellation and overlay
- **Searchable history**: thumbnails, tags, and full-text search (last 50 captures)
- **4 built-in presets**: Quick Capture, Research, Lecture Notes, Documentation
- **Context detection**: auto-selects preset based on the active app
- **URL scheme**: 11 routes for automation (see `caloura://help`)
- **7 customizable hotkeys** via Preferences
- **Sparkle auto-updates** (direct distribution)

## Keyboard Shortcuts

| Action | Default |
|--------|---------|
| Capture Area | `Ctrl+Shift+4` |
| Capture Window | `Ctrl+Shift+5` |
| Capture Full Screen | `Ctrl+Shift+3` |
| Repeat Last Area | `Ctrl+Shift+R` |

All shortcuts are customizable in Preferences > Shortcuts.

## Requirements

- macOS 14.0 (Sonoma) or later
- Screen Recording permission (prompted on first launch)

## Permissions Troubleshooting

If captures return blank images or the app reports "no permission":

1. Open **System Settings > Privacy & Security > Screen Recording**
2. Find **Caloura** in the list and toggle it **on**
3. If Caloura is not listed, click **+** and add it from `/Applications`
4. You may need to quit and relaunch Caloura after granting permission
5. On macOS 15 (Sequoia), you may be prompted to allow screen recording each time the app launches. This is an OS-level change and cannot be bypassed.

## Build

```bash
# Generate Xcode project (required after adding/removing source files)
xcodegen generate

# Build (Debug)
xcodebuild build -project Caloura.xcodeproj -scheme Caloura -configuration Debug

# Run tests
xcodebuild test -project Caloura.xcodeproj -scheme Caloura -configuration Debug

# Open in Xcode
open Caloura.xcodeproj
```

Requires Xcode 15+ and Swift 5.9.

## License

<!-- TODO: Choose license -->
