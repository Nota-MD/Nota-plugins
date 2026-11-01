# Vim profiles

This extension provides a working Vim input adapter for Nota's WYSIWYG editor.
The profiles are JSON data files loaded through `nota.assets.read()` and
`nota.json.decode()`.

- `profiles/classic-bsd-vi.json` follows the command set of POSIX/BSD vi.
- `profiles/modern-vim.json` extends it with Vim visual modes, text objects,
  multi-level undo, redo, macros and insert-mode navigation.
- `profiles.lua` validates and merges a profile. It defaults to `modern-vim`.

The profile chooses behavior and user vimrc-style mappings are applied as an
overlay. The panel can enable or disable the adapter, switch profiles, import a
JSON profile, and edit mappings. Disabling it restores native editor input
immediately.

Implemented modes and commands include normal, insert, visual and visual-line;
counts; `h/j/k/l`, word and line motions, `gg/G`, `f/t/F/T`; `d/c/y`, `x/X`,
`D/C/Y`, `p/P`, `r`, `J`, `u`/redo; text objects `iw` and `aw`; named and
unnamed registers; macros; dot repeat; `/`, `?`, `n`, `N`; and Ex commands for
save, close, line addressing, undo and redo.

The profiles explicitly keep unsupported promises off. Visual-block selection,
replace mode (`R`) and insert-mode `Ctrl-O` are not implemented in this
release; the built-in Modern Vim profile reports those features as disabled.

`/` is deliberately unambiguous: normal and visual modes map it to
`search.forward`; insert mode does not capture it, so it remains a literal
character. The old Nota line-start slash menu was removed for this reason.
