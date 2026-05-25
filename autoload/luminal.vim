" Autoload functions for vim-luminal.

let s:state = 'unknown'
let s:subscribed = 0

" Diagnostic state from the most recent initial-state probe; surfaced
" by :LuminalStatus.
let s:initial_source = ''
let s:initial_result = ''

" Persistent debug log. Off by default; flip g:luminal_debug = 1
" anywhere before vim startup completes to capture every subscribe,
" unsubscribe and on_dark/on_light call together with the call-stack,
" so a spurious theme flip can be traced back to whatever triggered
" it. Writes to file only — never echoes — so it cannot cause a
" hit-enter prompt.
func! s:log(msg) abort
    if !get(g:, 'luminal_debug', 0)
        return
    endif
    let path = get(g:, 'luminal_debug_file', expand('~/.cache/vim/luminal.log'))
    let dir = fnamemodify(path, ':h')
    if !isdirectory(dir)
        call mkdir(dir, 'p')
    endif
    call writefile([strftime('%F %T') . ' ' . a:msg], path, 'a')
endfunc

func! s:resolve(name) abort
    " Prefer luminal_*; fall back to lumen_* so an existing vim-lumen
    " setup is honoured without duplicating config.
    return get(g:, 'luminal_' . a:name . '_colorscheme',
                \ get(g:, 'lumen_' . a:name . '_colorscheme', ''))
endfunc

func! luminal#init() abort
    call s:log('init: tmux=' . (!empty($TMUX) ? 'yes' : 'no')
                \ . ' term=' . &term . ' TERM=' . $TERM)
    call luminal#subscribe()
    " A fresh DEC 2031 subscribe is not enough on its own: some
    " terminals only emit DSR on theme *changes* (not on subscribe),
    " and tmux relays subsequent changes to inner panes but never
    " replays the current state. Without an explicit initial probe we
    " would sit in 'unknown' until the user first toggles the theme.
    let initial = s:initial_state()
    call s:log('init: initial probe ' . s:initial_source
                \ . ' -> ' . (empty(initial) ? '(failed)' : initial))
    if initial ==# 'light'
        call luminal#on_light()
    elseif initial ==# 'dark'
        call luminal#on_dark()
    endif
endfunc

func! s:initial_state() abort
    " Inside tmux, ask the multiplexer directly — it tracks the outer
    " terminal's theme as #{client_theme} from 3.6+.
    if !empty($TMUX) && executable('tmux')
        let t = trim(system("tmux display-message -p '#{client_theme}'"))
        if t ==# 'light' || t ==# 'dark'
            let s:initial_source = "tmux '#{client_theme}'"
            let s:initial_result = t
            return t
        endif
    endif
    " Otherwise query the terminal's background colour via OSC 11 and
    " infer light/dark from luminance — same approach as `rod`
    " (terminal_colorsaurus). Done from a shell child so we can put
    " /dev/tty into raw mode briefly without disturbing vim's own
    " input handling.
    let s:initial_source = 'OSC 11 + luminance'
    let s:initial_result = s:detect_osc11()
    return s:initial_result
endfunc

func! s:detect_osc11() abort
    if !executable('sh')
        return ''
    endif
    " Strategy: put /dev/tty into non-canonical no-echo no-blocking
    " mode, send the OSC 11 query, give the terminal (and any ssh hop)
    " a beat to respond, then drain whatever has arrived in one read.
    " A blocking read with `dd bs=1 count=N` on a slow link tends to
    " return after the first chunk and miss the rest of the reply.
    let script = "old=$(stty -g </dev/tty 2>/dev/null) || exit 0\n"
                \ . "stty -echo -icanon min 0 time 0 </dev/tty 2>/dev/null\n"
                \ . "printf '\\033]11;?\\033\\\\' >/dev/tty\n"
                \ . "sleep 0.2\n"
                \ . "reply=$(dd bs=4096 count=1 </dev/tty 2>/dev/null)\n"
                \ . "stty \"$old\" </dev/tty 2>/dev/null\n"
                \ . "printf %s \"$reply\"\n"
    let reply = system(script)
    " Response: ESC ] 11 ; rgb:RRRR/GGGG/BBBB ESC \   (channels are
    " 1 to 4 hex digits per the xterm spec). Anchor on ']11;' so we
    " don't accidentally match an OSC 10 (foreground) reply that vim
    " itself may have just queried — both have identical 'rgb:...'
    " payloads and end up coalesced on the tty buffer.
    let m = matchlist(reply, '\]11;rgb:\(\x\+\)/\(\x\+\)/\(\x\+\)')
    if empty(m)
        return ''
    endif
    let r = str2nr(m[1], 16)
    let g = str2nr(m[2], 16)
    let b = str2nr(m[3], 16)
    let scale = max([r, g, b]) > 255 ? 65535.0 : 255.0
    " Rec. 709 relative luminance; dark/light at 50%.
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / scale > 0.5
                \ ? 'light' : 'dark'
endfunc

func! luminal#subscribe() abort
    call echoraw("\e[?2031h")
    let s:subscribed = 1
    call s:log('-> CSI ? 2031 h  (subscribe)')
endfunc

func! luminal#unsubscribe() abort
    call echoraw("\e[?2031l")
    let s:subscribed = 0
    call s:log('-> CSI ? 2031 l  (unsubscribe)')
endfunc

func! luminal#refresh() abort
    " Some terminals only send DSR on change; toggling resubscribes and
    " usually triggers an immediate fresh report.
    call luminal#unsubscribe()
    call luminal#subscribe()
endfunc

func! luminal#apply() abort
    let name = s:resolve(s:state)
    if empty(name) || get(g:, 'colors_name', '') ==# name
        return
    endif
    execute 'colorscheme ' . name
endfunc

func! luminal#on_dark() abort
    call s:log('<- dark  (prev state=' . s:state . ' bg=' . &background
                \ . ')  stack: ' . expand('<stack>'))
    if s:state ==# 'dark' && &background ==# 'dark'
        return
    endif
    set background=dark
    let s:state = 'dark'
    call luminal#apply()
    if exists('#User#LuminalDark')
        doautocmd User LuminalDark
    endif
endfunc

func! luminal#on_light() abort
    call s:log('<- light (prev state=' . s:state . ' bg=' . &background
                \ . ')  stack: ' . expand('<stack>'))
    if s:state ==# 'light' && &background ==# 'light'
        return
    endif
    set background=light
    let s:state = 'light'
    call luminal#apply()
    if exists('#User#LuminalLight')
        doautocmd User LuminalLight
    endif
endfunc

func! luminal#status() abort
    echo 'vim-luminal'
    echo '  subscribed         : ' . (s:subscribed ? 'yes' : 'no')
    echo '  last state         : ' . s:state
    echo '  &background        : ' . &background
    echo '  &colors_name       : ' . get(g:, 'colors_name', '(unset)')
    echo '  dark  colorscheme  : ' . (empty(s:resolve('dark'))  ? '(unset)' : s:resolve('dark'))
    echo '  light colorscheme  : ' . (empty(s:resolve('light')) ? '(unset)' : s:resolve('light'))
    echo '  &term / $TERM      : ' . &term . ' / ' . $TERM
    echo '  inside tmux        : ' . (!empty($TMUX) ? 'yes' : 'no')
    echo '  initial probe      : ' . (empty(s:initial_source) ? '(none)' : s:initial_source)
                \ . ' -> ' . (empty(s:initial_result) ? '(failed)' : s:initial_result)
    if get(g:, 'luminal_debug', 0)
        echo '  debug log          : ' . get(g:, 'luminal_debug_file',
                    \ expand('~/.cache/vim/luminal.log'))
    endif
endfunc
