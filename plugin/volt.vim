scriptencoding utf-8

if exists('g:loaded_volt')
  finish
endif
let g:loaded_volt = 1

command! -bar -nargs=+
\   VoltGet
\   call volt#get([<f-args>])
