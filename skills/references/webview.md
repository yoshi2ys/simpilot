# WebView Apps — Detailed Guide

WebView-based apps (Safari, Chrome, hybrid apps) require a different approach than native UIKit/SwiftUI apps. The key difference: **`elements` cannot see inside WebViews, but `source` can.**

## Decision Tree: Native vs WebView

```
Is the element visible in `elements --level 1`?
├── YES → Use `simpilot tap '<query>'` (the query field value)
└── NO  → It's inside a WebView
          ├── Use `simpilot source` to find coordinates
          └── Use `simpilot tapcoord <x> <y>` to interact
```

## Reading source as a DOM Inspector

`source` returns the full UI hierarchy in a format similar to a browser's DOM inspector. You can reconstruct the page layout from it without taking a screenshot:

```
StaticText, {{16.0, 120.0}, {370.0, 52.0}}, label: '金閣寺の拝観時間'
                ↑ origin (x, y)    ↑ size (w, h)       ↑ visible text
```

**Layout reconstruction from frames:**
- **y values** tell you vertical ordering — small y = top of screen, large y = bottom
- **x values** + widths reveal horizontal layout (side-by-side elements have similar y, different x)
- **Nesting depth** (indentation) shows containment — a Link inside an Other inside a WebView
- **Labels and values** give you the text content without needing visual recognition

**Practical workflow — use source to navigate without screenshots:**

```bash
# 1. Get page structure (like View Source in a browser)
simpilot source | python3 -c "
import json,sys
d=json.load(sys.stdin)
for line in d['data']['source'].split('\n'):
    # Filter for content elements, skip layout containers
    if any(t in line for t in ['StaticText', 'Link', 'Button', 'Image']):
        print(line)
" | head -30

# 2. From the output, you can infer:
#    - What text is visible on the page
#    - Where each element is positioned
#    - Which elements are links (tappable)
#    - The logical reading order (by y coordinate)

# 3. Tap the element you need by its coordinates
simpilot tapcoord <center_x> <center_y>
```

## Finding WebView Element Coordinates

`elements --level 1` does not list WebView-internal elements. Use `source` to get the full hierarchy including WebView internals, then extract coordinates:

```bash
# Search for a specific element in the WebView
simpilot source | python3 -c "
import json,sys
d=json.load(sys.stdin)
for line in d['data']['source'].split('\n'):
    if 'keyword' in line.lower():
        print(line)
"
# → Button, 0x..., {{16.0, 657.0}, {370.0, 10.0}}, label: 'Don't sign in'

# Calculate center: x = origin_x + width/2, y = origin_y + height/2
# In this case: x=16+370/2=201, y=657+10/2=662
simpilot tapcoord 201 662
```

## Overlay Dialogs (Sign-in Prompts, Cookie Banners, etc.)

WebView overlay dialogs (e.g., Google sign-in prompts, cookie consent banners) are rendered as part of the WebView content, not as native modals. This causes two problems:

1. **Visual coordinates are wrong**: A dialog button may *appear* at y≈460 on the screenshot, but `source` reveals the actual frame is at y=657. The discrepancy can be hundreds of points. **Never estimate coordinates from screenshots for WebView elements.**
2. **Taps penetrate overlays**: If you tap at the wrong coordinates, `tapcoord` hits the element *behind* the overlay (e.g., an image underneath), not the overlay button itself. This is why you may see an image viewer open when trying to dismiss a dialog.

**Always use `source` to get exact coordinates for WebView overlays.**

If `source` returns no matching lines, the overlay may not yet be in the DOM. Wait and retry, or scroll so the overlay re-renders.

## Floating UI Interference Zones

Modern apps often have floating UI elements (Safari's compact toolbar, bottom tab bars, floating action buttons, sticky headers) that intercept taps intended for content underneath. When you `tapcoord` a content element near these zones, **the app's chrome captures the tap** instead of the content — e.g., Safari's toolbar expands, a tab bar activates, or a sticky header receives the tap.

**Rule**: Keep `tapcoord` targets away from the screen edges where app chrome lives. If the target is too close to the top or bottom, scroll the content so the element moves to mid-screen first.

Screen sizes vary by device — use `simpilot info` to get the actual screen dimensions, then judge safe zones accordingly. As a guideline, avoid the top ~60pt and bottom ~80pt of the screen.

```bash
# Check screen size
simpilot info  # → screen dimensions in the response

# BAD: element near bottom edge — inside toolbar zone
simpilot tapcoord 200 810   # → toolbar expands, link not tapped

# GOOD: scroll so the element moves to mid-screen, then re-check coordinates
simpilot swipe up
simpilot source | python3 -c "..."  # find new y coordinate
simpilot tapcoord 200 400   # → element now in safe zone
```

Common interference zones (exact positions depend on device screen size):
- **Safari**: bottom toolbar expands on tap when minimized
- **Tab bar apps**: bottom tab bar switches tabs
- **Sticky headers**: top area may capture taps for navigation bar

## Duplicate Labels (Off-Screen Elements)

WebView apps often have **duplicate labels at off-screen positions** (e.g., y:5936). Bare label queries may match an off-screen element instead of the visible one. When a tap succeeds but nothing happens on screen, check for duplicates:

```bash
# Check for duplicates
simpilot elements --level 1   # compare frame.y values for same label

# If duplicate exists, fall back to tapcoord
simpilot tapcoord <x> <y>
```

## Swipe Targeting

- **`swipe` without `--on` targets the screen center**, which may trigger unintended gestures (e.g., tab switching in a paged UI). Always use `--on` with a specific element **inside** the scroll area.
- **Choose the right swipe anchor**: If a WebView has both horizontal tabs and horizontal scroll sections, target an element within the scroll area (e.g., a card label), not a nearby heading or link.
- **Vertical scroll** works well with `swipe up/down --on '<element>'` using a visible page element as anchor.

```bash
# BAD: may trigger tab switch instead of card scroll
simpilot swipe left
simpilot swipe left --on 'もっと見る'

# GOOD: target an element inside the scrollable area
simpilot swipe left --on '<card label text>'

# Vertical scroll
simpilot swipe up --on '<visible element>'
```

## Ads and Modals

- **WebView ad buttons may throw XCUITest exceptions** when tapped via label query. Use `tapcoord` instead.
- **Interstitial ads** often have a "Close Advertisement" button that starts as **Disabled** and becomes enabled after a few seconds. Use `sleep` + `tapcoord` to dismiss.

```bash
# Find close button (may be Disabled initially)
simpilot source | grep -i close

# Wait for it to become tappable, then tap by coordinate
sleep 5 && simpilot tapcoord 376 88
```

## Native vs WebView Elements

| Element location | Query method | Speed |
|---|---|---|
| Native tab bar | Bare label (`simpilot tap 'ホーム'`) | Fast |
| Native navigation bar | Identifier (`simpilot tap '#BackButton'`) | Fast |
| WebView-internal content | `tapcoord` (coordinates from `source`) | Fast |
| WebView-internal content | Bare label query | **Slow/Unreliable** |
