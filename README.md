# Hammer

<a href="http://0rwx.com/">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/AI-X-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="./assets/AI-X-light.svg">
    <img src="./assets/AI-X-light.png" alt="0rwx" width="50">
  </picture>
</a>

This project is mainly made for my own usage.

---

Plan9's `acme` is a great editor! It is said to do everything.

I want to do everything too! However, just because it has a timeless editing model
doesn't automatically make it nice to use. We want to modernize it!

Thus Hammer is born. When all you have is a hammer, **treat everthing as nails**.

## Building

Use Odin itself to build this project.

Remember to setup the submodule:

```bash
git submodule update --init --recursive
```

Run the build script (on the first Linux or Windows run it also downloads
the pinned Sokol C sources, verifies their checksum, and compiles the Sokol
static libraries):

```bash
odin run make.odin -file                    # debug build
odin run make.odin -file -- --release       # optimized build
odin run make.odin -file -- test            # core unit tests (headless)
odin run make.odin -file -- text-test       # pinned native text bindings (Linux)
```

Open an existing UTF-8 file and save edits with Ctrl+S:

```bash
./build/hammer filename
```

Save As (Ctrl+Shift+S) is deferred until tag commands can request a destination
path. Invalid UTF-8 and unsupported encodings are not converted implicitly.

The native text stack is pinned to FreeType 2.15.0, HarfBuzz 12.3.2, ICU4C
78.3 (Unicode 17.0, with unversioned C symbols), fontconfig 2.18.3, and
shaderc/glslc 2026.3. Linux product startup discovers and opens body/tag/
console faces through `src/text/fonts`; other platforms currently report font
discovery as unsupported. See `configs/example.yaml` for ordered role stacks
and the explicit `font_path` override.

### Configuration

Hammer's configuration is compiled into the binary (SPECS.md §14). The
build tool stages a trusted config file into a generated package on
every build; built-in oxocarbon defaults apply when none exists:

```bash
odin run make.odin -file -- --init-config ~/.config/hammer/config.yaml  # write an example
# edit the file, then rebuild — colors and font size change:
odin run make.odin -file -- --config ~/.config/hammer/config.yaml
```

`HAMMER_CONFIG=<path>` works like `--config`; `--no-config` forces the
built-in defaults. Malformed configs fail the build with file:line
errors. Project-local configs are never picked up automatically.

Linux/X11 requirements: a C compiler, binutils, and the X11/GL development
packages. Native Windows requires LLVM (`clang-cl`, `llvm-ar`, `lld-link`)
and a Windows SDK; the normal build produces `build/hammer.exe` and uses the
native CRT. The `windows` target still cross-builds from Linux with MinGW.
The first Sokol download also requires `curl`, `tar`, and `sha256sum` on PATH.
`make.odin` detects missing pieces and prints setup guidance.

Linux headless smoke test (window create/render/shutdown, needs `xvfb-run`):

```bash
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer
```

Native Windows smoke test:

```bash
HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer.exe
```
