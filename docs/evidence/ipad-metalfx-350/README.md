# Physical-iPad MetalFX validation — issue #350

Validated July 31, 2026 on an iPad Pro 11-inch (3rd generation, M1) running
iPadOS 26.6.

## Original failure

The first hardware launch aborted in `MTLFXSpatialScaler.encode` with MetalFX's
runtime assertion:

```text
outputTexture must have private storage mode
```

The renderer was assigning the physical iPad's `CAMetalDrawable` texture
directly to `MTLFXSpatialScaler.outputTexture`. That drawable is not a
private-storage texture.

## Fix

- MetalFX now writes to a full-resolution private texture.
- Texture descriptors include the scaler's reported input/output usage flags.
- `inputContentWidth` and `inputContentHeight` are set before each encode.
- The upscaled private texture is copied into the drawable for presentation.
- Drawable dimensions are treated as authoritative during rotation so a stale
  scaler is never used with a differently sized drawable.

## Validation

- `./ci/build-ipad.sh Debug`: simulator and arm64 device builds passed.
- Signed Release build passed with automatic Apple Development signing.
- Release `.app` installed directly with `devicectl`, without LLDB.
- The app remained alive beyond the frame that previously aborted.
- `./ci/check.sh`: green, including renderer and performance gates.
- The device test app was foregrounded away, terminated, and confirmed stopped.
- No simulator was booted during or after the hardware validation.

Issue #350 remains open for Roy's normal gameplay confirmation.
