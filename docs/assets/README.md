# Repository artwork

[social-preview.svg](social-preview.svg) is original project artwork, using the
cube geometry and face colours from [the launcher icon](../../launcher/Icon.swift).
It is a repository graphic, not a Minecraft screenshot or game asset. The source
preview label describes this repository; it does not announce a binary release.

Render a 1280 × 640 PNG locally before uploading it under GitHub repository
**Settings → General → Social preview**. From the repository root on a Mac with
Google Chrome installed:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --no-first-run --disable-extensions \
  --user-data-dir=/tmp/bedrock-mac-presentation-chrome \
  --screenshot=/tmp/bedrock-mac-presentation-social-preview.png \
  --window-size=1280,640 --force-device-scale-factor=1 --hide-scrollbars \
  "file://$PWD/docs/assets/social-preview.svg"
```

Inspect the PNG before upload. Keep generated PNGs outside the source checkout;
the exporter accepts this SVG as text without adding a binary exception.

Proposed repository topics: `minecraft`, `minecraft-bedrock`, `macos`,
`apple-silicon`, `wine`, `dxmt`. They describe the project and its compatibility
stack, without implying native ARM game execution or a stable app release.
