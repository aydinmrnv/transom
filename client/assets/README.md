# Mac Studio artwork

`mac-studio.png` is an offline render of Apple's actual Mac Studio USDZ model,
not a generated approximation or a drawing made from UI primitives.

- Source page: https://www.apple.com/mac-studio/
- Original model: https://www.apple.com/105/media/us/mac-studio/2026/e5b92529-6fd3-439c-9461-9d111718310f/ar/mac-studio-studio.usdz
- Retrieved: 2026-09-20
- Geometry, textures, product design and Apple marks: Apple Inc. The source model
  and derived product artwork are third-party assets, not covered by Transom's
  AGPL software license. No endorsement by Apple is implied.

Reproduce with Blender 4.5 LTS (offline authoring tool, not an app/build dependency):

```text
blender --background --python render_mac_studio.py -- mac-studio.usdz mac-studio.png
```

The Windows executable embeds the PNG. Windows Imaging Component decodes it once
per Direct2D target, preserving premultiplied alpha. The app does not download
artwork at runtime. The protocol does not report hardware model: Studio artwork
is used only for a host named Studio; other hosts use a neutral computer symbol.
