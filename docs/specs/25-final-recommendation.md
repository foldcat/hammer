# Final recommendation

Build around these five commitments:

1. **A persistent rope and transaction engine are the center of the editor.**
2. **Acme’s selection/execute/look and text-interface model remain the product identity.**
3. **Native clipboard, Unicode, DPI, file safety, and async execution are foundational—not optional polish.**
4. **Modern IPC is canonical, while filesystem access remains a supported first-class interface.**
5. **The coding agent completes one tested vertical slice at a time, following the active milestone and writing an exact handoff.**

The most important practical rule is:

> **Do not spend the first month adding highlighting, a finder, and Git markers to an unsafe text widget. Build the text model, platform integration, transaction semantics, and recovery guarantees first.**

### References

1. Rob Pike, _Acme: A User Interface for Programmers_: https://9p.io/sys/doc/acme/acme.html
2. Odin ecosystem/bindings references: https://github.com/jakubtomsu/awesome-odin and https://codeberg.org/mgavioli/odin-harfbuzz
3. Odin Tree-sitter bindings: https://github.com/laytan/odin-tree-sitter
4. Clipboard ownership and platform behavior overview: https://wiki.archlinux.org/title/Clipboard
