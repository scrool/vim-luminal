# vim-luminal

Terminal-driven dark/light detection for Vim:

- subscribes to **runtime** theme changes via [DEC private mode 2031][dec2031];
- computes the **initial** state by reading the terminal's background colour
  through OSC 11 and converting the rgb reply to dark/light via Rec. 709
  relative luminance;
- has **first-class support** for Vim running inside tmux (uses
  `#{client_theme}` for the initial probe, DEC 2031 forwarded by tmux for
  runtime updates, and a `list-clients`-by-activity query to stay correct
  when the same tmux session is attached from multiple clients with
  different themes).

Everything happens over the controlling terminal — no D-Bus, AppleScript or
Windows registry lookups, and therefore no dependency on a graphical desktop
session.

[dec2031]: https://contour-terminal.org/vt-extensions/color-palette-update-notifications/

## What it fixes

[`vim-lumen`][lumen] (and similar plugins) detect the system theme by
talking to OS-level APIs on the machine where Vim runs. That falls over for
the common setup of running Vim on a **headless remote server over SSH**:
there is no `xdg-desktop-portal`, no `defaults read -g`, no Windows
registry — only a PTY back to your laptop's terminal.

Modern terminal emulators (Ghostty, Contour, kitty, …) solve this for terminal
clients with DEC mode 2031: applications subscribe with `CSI ? 2031 h` and the
terminal sends a DSR (`CSI ? 997 ; 1|2 n`) whenever the OS theme flips.
`vim-luminal` implements exactly that handshake in pure Vimscript, so theme
tracking works over `terminal → ssh → (tmux) → vim` without anything else
installed on the remote.

[lumen]: https://github.com/vimpostor/vim-lumen

### How it works

1. On `VimEnter`, send `CSI ? 2031 h` to the controlling terminal to
   subscribe to theme reports.
2. The DSR replies `CSI ? 997 ; 1 n` (dark) and `CSI ? 997 ; 2 n` (light)
   are bound to `<F36>`/`<F37>` via `set <Fn>=...` and dispatched through
   `<Cmd>`-based mappings in every mode, so a runtime theme flip is picked
   up while you're in insert, visual, cmdline, or a `:terminal` job.
3. The current state at startup is queried explicitly, because not all
   terminals reply on subscribe and tmux never replays the current state to
   a freshly-subscribed inner pane:
   - inside tmux: `tmux list-clients -t $TMUX_PANE -F '#{client_activity}
     #{client_theme}'`, then the theme of the client with the most recent
     input activity is taken — this is the user actually in control;
   - otherwise: OSC 11 (`ESC ] 11 ; ? ESC \`) is sent via a short shell
     child reading `/dev/tty` in raw mode, and the rgb reply is converted
     to light/dark via Rec. 709 relative luminance — the same approach
     used by [`rod`](https://github.com/leiserfg/rod) and
     [`terminal_colorsaurus`](https://crates.io/crates/terminal-colorsaurus).
4. Inside tmux, the same `list-clients` query is re-issued on the standard
   "user came back" and "user went idle" autocmds (`FocusGained`,
   `CursorHold`, `CursorHoldI`). This catches the case where the same tmux
   session is attached from **multiple clients with different themes**:
   when you switch from the dark-themed terminal to the light-themed one
   (or vice versa), Vim picks up the change without any tmux config.
5. For the same multi-client setup, DSR replies arriving via the input
   mappings are cross-checked against the active tmux client's theme and
   silently dropped when they disagree, so a stale DSR from a non-active
   client can't override the correct state.
6. On `VimLeavePre`, `CSI ? 2031 l` is sent to unsubscribe cleanly.

## Requirements

- Vim with `echoraw()` (patch **8.2.2351** or newer). Neovim already has
  native equivalent support — see *Status* below.
- A terminal that implements DEC mode 2031 (Ghostty, foot, Contour,
  WezTerm, …) for **runtime** theme tracking.
- For initial-state detection on the non-tmux path, a terminal that
  answers OSC 11 and a working `sh` on the host running Vim.

## Installation

The plugin ships as a standard Vim runtime layout (`plugin/`, `autoload/`,
`doc/`). Pick whichever installer matches the rest of your setup.

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'scrool/vim-luminal'
```

### Native Vim 8+ packages (no plugin manager)

```sh
git clone https://github.com/scrool/vim-luminal \
    ~/.vim/pack/plugins/start/vim-luminal
vim -u NONE -c "helptags ~/.vim/pack/plugins/start/vim-luminal/doc" -c q
```

### [Pathogen](https://github.com/tpope/vim-pathogen)

```sh
git clone https://github.com/scrool/vim-luminal ~/.vim/bundle/vim-luminal
```

### [Vundle](https://github.com/VundleVim/Vundle.vim)

```vim
Plugin 'scrool/vim-luminal'
```

### [lazy.nvim](https://github.com/folke/lazy.nvim) (Neovim)

```lua
{ "scrool/vim-luminal" }
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim) (Neovim)

```lua
use "scrool/vim-luminal"
```

### [mini.deps](https://github.com/echasnovski/mini.deps) (Neovim)

```lua
require("mini.deps").add({ source = "scrool/vim-luminal" })
```

After install, run `:helptags ALL` (or your plugin manager's equivalent)
once so `:help luminal` works.

## Configuration

There are three independent ways to react to a theme change. They can be
combined; pick whichever fits the rest of your config best.

### 1. Plugin-native variables

```vim
let g:luminal_dark_colorscheme  = 'moonfly'
let g:luminal_light_colorscheme = 'PaperColor'
```

### 2. vim-lumen-compatible variables (fallback)

If `g:luminal_*_colorscheme` is unset, the plugin falls back to
`g:lumen_*_colorscheme`, so an existing `vim-lumen` configuration keeps
working unchanged.

```vim
let g:lumen_dark_colorscheme  = 'moonfly'
let g:lumen_light_colorscheme = 'PaperColor'
```

### 3. `OptionSet background` autocmd

Every theme report runs `set background=dark|light`, which fires
`OptionSet background`. If neither set of variables above is defined, no
colorscheme is applied automatically; you stay in full control:

```vim
autocmd OptionSet background
      \ execute 'colorscheme '
      \ . (&background ==# 'dark' ? 'moonfly' : 'PaperColor')
```

This matches the style that becomes recommended once native DEC 2031
support lands in Vim itself (see *Status*).

## Commands

| Command                | Description                                          |
| ---------------------- | ---------------------------------------------------- |
| `:LuminalStatus`       | Show subscription state, last detected theme, current `'background'`/`'colors_name'`, configured colorschemes, `&term`/`$TERM`, tmux state, which probe supplied the initial value, and timings (init cost and last tmux query) so you can quantify the plugin's startup overhead. |
| `:LuminalRefresh`      | Send `CSI ? 2031 l` then `CSI ? 2031 h` (some terminals reply with a fresh DSR after a resubscribe). |
| `:LuminalSubscribe`    | Send `CSI ? 2031 h` manually. Done automatically on `VimEnter`. |
| `:LuminalUnsubscribe`  | Send `CSI ? 2031 l` manually. Done automatically on `VimLeavePre`. |

## User autocommands

```vim
autocmd User LuminalDark  let $BAT_THEME = 'gruvbox-dark'
autocmd User LuminalLight let $BAT_THEME = 'gruvbox-light'
```

## Status

This plugin is intended to become **obsolete** once Vim itself implements
DEC mode 2031 natively, tracked upstream as
[vim/vim#17251](https://github.com/vim/vim/issues/17251). When that ships,
configuration form 3 above (the `OptionSet background` autocmd) keeps
working unchanged — you just remove this plugin.

Neovim already ships the equivalent functionality through
[neovim/neovim#31350](https://github.com/neovim/neovim/pull/31350).

## Why "vim-luminal"?

The name is a portmanteau of **lumen** + **liminal** — a nod to
[`vim-lumen`][lumen], whose goal (have Vim follow the system theme
preference) and configuration surface served as the inspiration here, and
the *liminal* boundary between dark and light that the plugin pivots on.

The two plugins differ in *how* they get there:

|                                | vim-lumen                                    | vim-luminal                                            |
| ------------------------------ | -------------------------------------------- | ------------------------------------------------------ |
| Subscribe to runtime changes   | OS APIs (D-Bus, AppleScript, Win registry)   | DEC mode 2031 over the controlling terminal            |
| Initial state                  | Same OS APIs                                 | OSC 11 + Rec. 709 luminance (or tmux `#{client_theme}`)|
| Works on a headless server     | no                                           | yes                                                    |
| reached over SSH               |                                              |                                                        |
| Required dependencies on host  | `gdbus` / Swift / Win32 APIs                 | `sh` (only for the OSC 11 fallback)                    |

Configuration is intentionally interface-compatible: if you already have
`g:lumen_dark_colorscheme` and `g:lumen_light_colorscheme` set,
`vim-luminal` picks them up automatically without any change to your vimrc.

## License

[MIT](LICENSE)
