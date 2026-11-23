# Hammer

<a href="http://0rwx.com/">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/AI-X-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="./assets/AI-X-light.svg">
    <img src="./assets/AI-X-light.png" alt="0rwx" width="50">
  </picture>
</a>

---

> It is tempting, if the only tool you have is a hammer, to treat everything as if it were a nail.

Hammer is a text editor that aims to be a modernized `acme` from plan9 with more
features and improved text rendering. It is cross platform (mainly X11, the other
platforms are secondary targets). This text editor hopefully has the ability to
handle all the coding tasks you throw at it.

If you don't know what `acme` is, it turns your editor into a shell. You can do the following:

- Type the compile command on the tagbar, highlight it and midclick to run, command output
  appears, you right click on the error position as denoted by the compiler, the cursor
  instantly jumps there
- Right click a path and just jump there
- Pipe the entire buffer into a command line util and get the return of it, like using `jq`
  to format the JSON in the buffer
- Don't forget a literal terminal emulator is built in
- Turn every single buffer into a scratchpad
- Debug in the editor without needing an extra terminal: run `curl`, start `docker compose`,
  and more commands
- You can rearrange and tile buffers intuitively

Hammer also has plenty more features if you know `acme`

- Keybinds that you expect, like control + c or control + s
- Tweakable colorscheme, dark mode by default
- Clipboard integration that works
- Autopair
- GPU rendered text
- The ability to use different fonts and render weird unicode characters
- Ligature support
- The ability to scale the font size
- A terminal emulator that renders most escape sequences
- Simple Raku language wrapper
- Basic Windows support

It is currently not completed yet, though it is usable.

## Is Hammer for me?

Maybe? This project is mainly made for myself and I'm not an acme purist, though you
may be able to get some value out of it.

It is for you if...

- You like the original `acme` but you want something a bit more modern.
- You want a tight debugging loop and command output piping ability.
- You want an editing model that is well fitted for most coding languages.

It is not for you if...

- You expect 100% compatability with the orignal `acme`.
- You hate the additional features I put in.
- You expect it to follow the spirit of `acme` entirely.
- You hate keybinds.
- You want to use LSP (it is not planned).
- You expect a plugin system (we have something like that but it is probably not what you think it is).
- You expect Vim like editing model.
- You hate mouse.

## Building

Use Odin itself to build this project.

Remember to setup the submodule:

```bash
git submodule update --init --recursive
```

Run the build script, it also downloads the pinned Sokol C sources, checksums
them and compiles them:

```bash
odin run make.odin -file                    # debug build
odin run make.odin -file -- --release       # optimized build
odin run make.odin -file -- test            # core unit tests (headless)
odin run make.odin -file -- text-test       # pinned native text bindings (Linux)
```

Open an existing UTF8 file and just try it out (or use the directory menu).

```bash
./build/hammer filename
```

The text stack we use is pinned to FreeType 2.15.0, HarfBuzz 12.3.2, ICU4C
78.3 (Unicode 17.0, with unversioned C symbols), fontconfig 2.18.3, and
shaderc/glslc 2026.3. Linux product startup discovers and opens body/tag/
console faces through `src/text/fonts` while other platforms currently report font
discovery as unsupported (Windows' font discovery kinda works but it's not tested
much). See `configs/example.yaml` for ordered role stacks and the explicit
`font_path` override.

### Configuration

Hammer takes the Suckless configuration approach, which means your config is compiled
directly into the binary. It is really not that big of a deal considering
building hammer takes less than 0.5 seconds (on my device). If not set, we use
the built in Oxocarbon colorscheme with my own personal modification.

```bash
odin run make.odin -file -- --init-config ~/.config/hammer/config.yaml  # write an example
# edit the file, then rebuild colors and font size change:
odin run make.odin -file -- --config ~/.config/hammer/config.yaml
```

`HAMMER_CONFIG=<path>` works like `--config`, `--no-config` forces the
built in defaults. Malformed configs fail the build with file:line
errors. Project local configs are never picked up automatically.

Linux/X11 needs a C compiler, binutils, and the X11/GL development
packages. Native Windows requires LLVM (`clang-cl`, `llvm-ar`, `lld-link`)
and a Windows SDK. The normal build produces `build/hammer.exe` and uses the
native CRT. The `windows` target still cross builds from Linux with MinGW for
testing purposes only. The first Sokol download also requires `curl`, `tar`,
and `sha256sum` on PATH. `make.odin` detects missing pieces and prints setup guidance.

We do smoke test it (window create/render/shutdown, needs `xvfb-run`):

```bash
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer
```

Native Windows smoke test:

```bash
HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer.exe
```
