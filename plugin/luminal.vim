" vim-luminal: dark/light detection via DEC private mode 2031.
"
" Sends CSI ? 2031 h to subscribe; parses CSI ? 997 ; {1,2} n DSR replies
" (1 = dark, 2 = light), flips 'background', and (optionally) applies a
" colorscheme. Works wherever the terminal (and any intermediate
" multiplexer) honour DEC 2031; no D-Bus / OS-level integration needed.
"
" See :help luminal for details.

if exists('g:loaded_luminal') || !has('patch-8.2.2351')
    " echoraw() is required to emit raw escape sequences to the tty.
    finish
endif
let g:loaded_luminal = 1

" Bind the two DSR replies to function-key codes so vim's input parser
" can match them and dispatch to mappings. <F36> = dark, <F37> = light.
execute "set <F36>=\e[?997;1n"
execute "set <F37>=\e[?997;2n"

" DSR replies from the terminal arrive asynchronously: a theme flip can
" land while you are mid-insert, in visual selection, halfway through a
" `:` command, or interacting with a :terminal job. The mapping must
" therefore work in every mode AND must not disturb that mode when it
" fires.
"
" <Cmd>... <CR> runs the Ex command in a normal-mode-equivalent context
" without actually leaving the current mode: no cursor move, no Insert
" abort, no Visual cancel, no `:` echo in the cmdline. Compared to the
" classic `:call ...<CR>` form it is silent and side-effect free, which
" is exactly what an out-of-band notification handler wants.
"
" The three map families cover the modes <Cmd> is valid in:
"   noremap   - normal, visual, select, operator-pending
"   noremap!  - insert, cmdline
"   tnoremap  - terminal-job (guarded; older vims lack :tnoremap)
noremap  <silent> <F36> <Cmd>call luminal#on_dark()<CR>
noremap! <silent> <F36> <Cmd>call luminal#on_dark()<CR>
noremap  <silent> <F37> <Cmd>call luminal#on_light()<CR>
noremap! <silent> <F37> <Cmd>call luminal#on_light()<CR>
if exists(':tnoremap') == 2
    tnoremap <silent> <F36> <Cmd>call luminal#on_dark()<CR>
    tnoremap <silent> <F37> <Cmd>call luminal#on_light()<CR>
endif

command! LuminalStatus      call luminal#status()
command! LuminalRefresh     call luminal#refresh()
command! LuminalSubscribe   call luminal#subscribe()
command! LuminalUnsubscribe call luminal#unsubscribe()

augroup luminal
    autocmd!
    autocmd VimEnter     * call luminal#init()
    autocmd VimLeavePre  * call luminal#unsubscribe()
    " Inside tmux, the OS theme can effectively change without any DEC
    " 2031 traffic — e.g. when the same session is followed from two
    " clients with different themes and the user switches between them.
    " Re-ask tmux on the standard "user came back" / "user went idle"
    " events; the canonical Vim idiom for picking up out-of-band state
    " changes (same one :checktime and gitgutter use).
    if !empty($TMUX)
        autocmd FocusGained * call luminal#refresh_from_tmux()
        autocmd CursorHold  * call luminal#refresh_from_tmux()
        autocmd CursorHoldI * call luminal#refresh_from_tmux()
    endif
augroup END
