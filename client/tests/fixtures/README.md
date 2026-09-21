# HEVC decoder regression fixture

`hevc-main.wire` contains a Transom config packet followed by 12 HEVC Main
4:2:0 8-bit frames, 128×96 at 12 fps, with no B frames. The source is a generated
FFmpeg `testsrc2` pattern; no user's screen or other personal data is included.
Run `python tests/fixtures/generate.py` from `client/` to regenerate it with
FFmpeg/libx265 and ffprobe installed. Encoder versions can change fixture bytes.

The test feeds the actual hvcC/length-prefixed wire samples into Windows Media
Foundation and checks decoded size and non-neutral colors. It caught the bogus
CLSID and missing Annex B conversion that unit tests of the wire could not.

Run explicitly on a Windows machine with HEVC Video Extensions installed:

```powershell
cargo test decodes_hevc_fixture_on_windows -- --ignored --nocapture
```

It is ignored in ordinary CI because codec availability on hosted runners is
not a product guarantee. Other parser, queue, and buffer-layout tests run in CI.
