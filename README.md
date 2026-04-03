# SlideTabSafari

A lightweight, background macOS menu-bar application that lets you switch between Safari tabs using trackpad gestures.

## Why does this exist?
Natively in macOS, performing a two-finger horizontal swipe in Safari triggers the "Back/Forward" history navigation. SlideTabSafari intercepts the horizontal scrolling at the system level before it reaches Safari, consumes the event so you don't accidentally go back in history, and instead injects native `Control+Tab` shortcuts to quickly navigate through your open tabs. 

## Features
- **Zero Configuration:** Works out of the box with standard macOS keyboard shortcuts (`Control+Tab`). Layout independent.
- **Silent & Unobtrusive:** Runs entirely in the background from your Menu bar. No Dock icon, no messy panels.
- **Smart Resource Usage:** Idles with almost 0 CPU usage because it only evaluates `CGEvent` scrolls when `com.apple.Safari` is currently the active application.

## Installation & Building

Since this application intercepts global hardware events, it requires Accessibility permissions. To make this safe and transparent, the application is compiled entirely locally on your machine from a single pure Swift file.

### Prerequisites
- macOS
- Xcode Command Line Tools (Usually already installed. If not, run `xcode-select --install`)

### Building the App
1. Clone this repository:
   ```bash
   git clone https://github.com/Dmian0/SlideTabSafari.git
   cd SlideTabSafari
   ```
2. Run the build script to compile the Swift source and generate the code-signed App bundle (`SlideTabSafari.app`):
   ```bash
   chmod +x build.sh
   ./build.sh
   ```
3. Once compiled, launch the app directly:
   ```bash
   open SlideTabSafari.app
   ```

## Granting Permissions

To intercept trackpad events and simulate keystrokes, macOS requires explicit consent:
1. When you first open the app, it will prompt you for **Accessibility** permissions.
2. Go to **System Settings > Privacy & Security > Accessibility**.
3. Enable the toggle for `SlideTabSafari` in the list.
4. The application handles the rest! You will see a `⇥` icon in your Menu bar.

## Usage
- Open Safari with multiple tabs.
- Perform a **two-finger horizontal swipe** on your trackpad.
- The app will seamlessly switch to the adjacent tab instead of navigating the page history.
- To quit the app, simply click the `⇥` icon in your menu bar and select **Quit**.

## How It Works Under The Hood
The app utilizes a `CGEventTap` (`.cghidEventTap`) to observe raw `.scrollWheel` HID events before any application processes them. A mini state machine accumulates horizontal delta values. When the horizontal movement hits a specific threshold, it consumes the trackpad event sequence (returning `nil` in the tap callback) and posts a `CGEvent` keyboard injection (`Control+Tab` or `Control+Shift+Tab`). 

## License
[MIT License](LICENSE)
