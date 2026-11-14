# 14. Configuration and EditorConfig

## 14.1 Compiled Odin configuration

Use a trusted Odin source file compiled into the editor.

Suggested workflow:

```text
acme-build --config ~/.config/acme-next/config.odin
```

The build tool stages the source into a generated package with a known schema.

Avoid requiring users to modify the Odin installation’s shared package directories.

## 14.2 Configuration schema

Illustrative schema:

```odin
package config

Theme :: struct {
    body_bg:      [4]f32,
    body_fg:      [4]f32,
    tag_bg:       [4]f32,
    tag_fg:       [4]f32,
    selection_bg: [4]f32,
    selection_fg: [4]f32,
    caret:        [4]f32,
    git_added:    [4]f32,
    git_modified: [4]f32,
    git_deleted:  [4]f32,
}

Config :: struct {
    font_families:    []string,
    font_size_points: f32,
    line_height:      f32,
    ligatures:        bool,
    theme:            Theme,
}
```

The actual configuration should also support:

- Tag/body/console font roles.
- Keybindings.
- Touchpad bindings.
- Syntax style palette.
- Large-file thresholds.
- History budgets.
- Recovery interval.
- Shell configuration.
- Clipboard selection policy.
- Finder exclusions.
- Terminal settings.

## 14.3 Compile/apply workflow

`ConfigBuild` should:

1. Save the config file if requested.
2. Start an asynchronous build.
3. Display compiler output in an Acme output window.
4. Keep the existing editor running if compilation fails.
5. On success, offer restart/handoff.
6. Persist layout and recovery state before replacement.

On Windows, replacing a running executable requires a staged/versioned binary and launcher strategy.

Do not simply attempt to overwrite the running executable.

## 14.4 Trust boundary

An Odin configuration file is executable code.

Therefore:

- Only explicitly trusted user configuration is compiled.
- Never automatically compile a project-local config just because a repository contains one.
- Project layout/session files should use a non-executable format.
- By default, use the modified oxocarbon colorscheme. See `colorscheme.yaml`.

## 14.5 EditorConfig

Support standard semantics, not a home-grown approximation.

Important properties:

```text
root
indent_style
indent_size
tab_width
end_of_line
charset
trim_trailing_whitespace
insert_final_newline
```

Also support:

- Glob matching.
- Parent traversal.
- Property precedence.
- `unset`.
- Unsupported-property diagnostics where appropriate.

## 14.6 Effective settings layers

Recommended precedence:

```text
built-in defaults
 -> compiled user defaults
 -> project/session overrides where allowed
 -> EditorConfig file settings
 -> explicit current-buffer override
```

Keep visual preferences separate from file-format preferences.

EditorConfig should not set theme colors or font families.

## 14.7 Save-time transformations

If EditorConfig requires trimming or a final newline:

- Apply as a visible transaction.
- Make it undoable.
- Do not silently transform content after recording a “saved” checkpoint.
- Avoid modifying an in-flight save snapshot inconsistently with the visible buffer.
