**Apple Silicon, macOS 14 or later.**

### Install

1. Download `OfflineTranslate-*.dmg` below and drag **Offline Translate** into Applications.
2. The app isn't notarized by Apple yet, so macOS blocks it the first time. Run this once in Terminal:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Offline Translate.app"
   ```
   (or open it, then allow it under System Settings → Privacy & Security → **Open Anyway**).
3. Open the app and follow the Welcome window.

When you update, macOS may ask for the Accessibility permission again: remove the old entry in
System Settings → Privacy & Security → Accessibility and add the app again.
