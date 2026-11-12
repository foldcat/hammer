# Hammer

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
```

Linux/X11 requirements: a C compiler, binutils, and the X11/GL development
packages. `make.odin` detects missing pieces and prints the packages to
install.

Headless smoke test (window create/render/shutdown, needs `xvfb-run`):

```bash
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer
```
