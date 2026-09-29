# Project context

## MoonPainter (MoonBit, /deepStudio/moonpainter)
- A 100% MoonBit, zero-third-party-dependency "agent-driven layered bitmap drawing engine" (a bitmap-domain successor to moonviz). Assume no external crates are allowed in this codebase.
- `.mpd` is a ZIP container and the single source of truth: metadata layer `meta/design.json` (canonical, diffable) + content-addressed pixel layer `assets/sha256/<hash>`; fingerprint = `sha256(canonical design.json)` stored in the manifest and checked on unpack for tamper detection.
- Package dependency chain is strictly one-directional: `base`(SHA-256) ← `codec`(ZIP/DEFLATE/PNG) ← `core`(IR + canonical JSON) ← `render`(raster/blend/pick) ← `mpd`(container) ← `agent`(commands/undo/vision) ← `cli`(FFI, native-only). Never introduce a reverse dependency. Confidence: 0.7
- Completion bar (AGENTS.md rule): `moon check` with 0 errors *and* 0 warnings, plus a fully green `moon test --target native`. Confidence: 0.7
- Output bytes must stay deterministic: fixed DOS timestamps, hand-written JSON key order; timestamps, randomness, and hash-map iteration order must never reach output bytes, because render golden sha256 values are hard-locked. Confidence: 0.7
- Every rejection/validation path is expected to have a negative test. Confidence: 0.6
- The "vision gate" is intentional: `session-open full_image` is the only legal way to open a session and non-multimodal models are rejected by design — do not add bypasses. Confidence: 0.6
- Core model: `Document{Layer[] bottom-to-top, assets, params}`; `ShapeKind = Rect/Ellipse/Line/Polygon/Image/Group`; 7 blend modes; Fill is three-state (none/solid/linear). Transforms only change placement parameters and must never resample pixels; groups composite directly with no offscreen buffer. Confidence: 0.65
- Known, accepted limitations (do not "fix" unasked): 2x2 subsampled AA (1px jaggies), mediocre fixed-Huffman compression, no stroke for polygon/image/group, no live param binding, no palette/interlaced PNG (palette PNGs are rejected), P4 masks / P5 adjustment layers / text / bezier are out of scope. Confidence: 0.6
