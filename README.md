# Hammer

<a href="http://0rwx.com/">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/AI-X-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="./assets/AI-X-light.svg">
    <img src="./assets/AI-X-light.png" alt="0rwx" width="50">
  </picture>
</a>

I will NOT sugar coat. This project is completely vibe coded with minimal human 
review made for my own personal use.

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

Run the build script (on the first Linux run it also downloads the pinned
Sokol C sources, verifies their checksum, and compiles the Sokol static
libraries):

```bash
odin run make.odin -file                    # debug build
odin run make.odin -file -- --release       # optimized build
odin run make.odin -file -- test            # core unit tests (headless)
odin run make.odin -file -- text-test       # pinned native text bindings (Linux)
```

M05.01 adds narrow Linux bindings for FreeType 2.15.0, HarfBuzz 12.3.2,
and ICU4C 78.3 (Unicode 17.0, with unversioned C symbols). The text test
requires those exact `pkg-config` versions plus shaderc/glslc 2026.3. These
libraries are not yet used for product font rendering; M05.02 begins that
integration.

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
packages. `make.odin` detects missing pieces and prints the packages to
install.

Headless smoke test (window create/render/shutdown, needs `xvfb-run`):

```bash
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer
```
