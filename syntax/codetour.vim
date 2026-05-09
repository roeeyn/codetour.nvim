" Vim syntax file for codetour's :TourEdit list buffer
" Filetype is set programmatically by edit.lua when the buffer is created.

if exists('b:current_syntax')
  finish
endif

" Header / help comment lines, e.g. `# codetour ─ tour: auth  ·  3 stop(s)`
syntax match codetourComment "^#.*$" contains=codetourCommentSep,codetourCommentName

" The em-dash that separates segments inside the comment header
syntax match codetourCommentSep "─" contained
" The tour name in the header line
syntax match codetourCommentName "tour: \zs\S\+" contained

" Stop entry's `[N]` index marker — the identifier the parser keys off
syntax match codetourStopIdx "^\[\d\+\]"

" The em-dash that separates `file:lnum` from the editable note
syntax match codetourSep " ─ "

" file:lnum chunk — display-only metadata, edits are ignored
syntax match codetourFileLnum "\v\] +\zs[^ ]+\ze  ─"

highlight default link codetourComment      Comment
highlight default link codetourCommentSep   Conceal
highlight default link codetourCommentName  Identifier
highlight default link codetourStopIdx      Number
highlight default link codetourSep          Comment
highlight default link codetourFileLnum     Special

let b:current_syntax = 'codetour'
