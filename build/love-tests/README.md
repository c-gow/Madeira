# LOVE test programs for Madeira

Two LOVE 11 programs for checking Madeira's OpenGL ES path (winios GL driver,
`build/win32u-unix/opengl_ios.c`), the GC64 LuaJIT swap, audio and input,
without a commercial game or Steam in the way.

- `hello/`: a smoke test. It shows an animated window with text and an FPS
  counter, and writes `hello.txt` after the first frame and then every 5 seconds.
- `suite/`: about 15 seconds of automated checks. Each stage renders into an
  offscreen canvas, reads the pixels back and records PASS / FAIL / INFO in
  `results.txt`. The stages are:

  | Stage | What it checks |
  |---|---|
  | renderer info | GLES context, limits, features, canvas formats |
  | clear, shapes, texture, blend, stencil, text | basic rasterisation paths |
  | shader | LOVE's GLSL-to-GLES shader path, via texture coordinates |
  | screenshot | readback of the default framebuffer (opengl32's FBO emulation) |
  | spritebatch | throughput: 2000 streamed sprites, FPS recorded |
  | resize | `love.window.setMode` to 1280x720, which may recreate the context |
  | audio | a generated tone has to advance `Source:tell()` (catches driver stalls) |
  | input | 6 seconds to tap, click or type; the events are counted |

## Running

1. Download `love-11.5-win64.zip` from https://github.com/love2d/love/releases
   and unzip it.
2. Build a drop-in folder and copy it onto the phone:
   ```bash
   build/love-tests/pack.sh ~/Downloads/love-11.5-win64 --install
   ```
   This fuses `hello.exe` and `suite.exe` onto `love.exe`, the same way Balatro
   ships, and copies them with LOVE's DLLs to `C:\madeira-love-tests`.
3. In Madeira's desktop, open **Run** and start `C:\madeira-love-tests\hello.exe`,
   then `C:\madeira-love-tests\suite.exe`.
4. Pull the results:
   ```bash
   build/love-tests/pack.sh --results
   ```
   Fused LOVE games save to `%APPDATA%\madeira-love-tests\`, for example
   `C:\users\mythic\AppData\Roaming\madeira-love-tests\` (the user name
   depends on the prefix).

Because `love.dll` and `lua51.dll` sit next to the exes, the first launch swaps
in the GC64 LuaJIT (`[love-compat]` in the Madeira log), exactly as for Balatro.
