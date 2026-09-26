# compat/love/ — LuaJIT for LOVE games (not tracked)

`build/luajit-x64/build.sh` builds `lua51.dll` (GC64 LuaJIT, x86-64) here; it
is git-ignored. At launch Madeira copies it into LOVE game folders in place of
their own `lua51.dll` (`ios_love_compat` in `build/ntdll-unix/process_ios.c`).
Without it LOVE games keep their stock LuaJIT, which needs memory below 2 GB and
fails on iOS.
