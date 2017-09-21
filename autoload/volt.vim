scriptencoding utf-8

let s:IS_WIN = has('win16') || has('win32')
\               || has('win64') || has('win95')
let s:PATH_SEP = s:IS_WIN ? '\' : '/'
let s:VOLT_MSG_BUFNAME = '[VOLT_MSG]'
let s:NIL = []
let s:REPO_DIR = expand('<sfile>:h:h')

let s:plugconf = {}

function! volt#get(args) abort
  " Get volt command fullpath
  let volt_cmd = s:Path.volt_cmd()
  if getfperm(volt_cmd) !~# '^..x'
    call s:msg_buffer('[INFO] Invoking bootstrap.vim ...')
    let $VOLT_NOGUIDE = '1'
    try
      source `=s:REPO_DIR . '/bootstrap.vim'`
    catch
      call s:msg_buffer('[ERROR] ' . v:exception . "\n" . v:throwpoint)
      return
    endtry
  endif

  " Execute 'volt get ...'
  let volt_get = join([volt_cmd, 'get'] + a:args)
  call s:msg_buffer(printf("[INFO] Executing '%s'", volt_get))
  let out = system(volt_get)
  for line in (out =~# '\S' ? split(out, '\n', 1) : '')
    call s:msg_buffer('[OUT] ' . line)
  endfor

  " Get last transacted vim plugins:
  " compare trx_id and repos[]/trx_id and get matched repos[]/path
  let [lock_json, err] = s:read_lock_json()
  if err isnot s:NIL
    call s:msg_buffer('[ERROR] Could not read lock.json: ' . err.msg)
    return
  endif
  for repos in s:get_last_transacted_repos(lock_json)
    let fullpath = s:Path.full_repos_path_of(repos.path)
    if !s:rtp_has(fullpath)
      let &rtp .= ',' . fullpath
      for file in glob(fullpath . '/plugin/**/*.vim', 1, 1)
        source `=file`
      endfor
    endif
    helptags `=fullpath`
    let plugconf = s:Path.plugconf_of(repos.path)
    if filereadable(plugconf)
      source `=plugconf`
    endif
    call volt#run_hooks('hook_post_update', repos.path)
  endfor
endfunction

function! volt#run_hooks(event, ...) abort
  for path in a:0 is 0 ? keys(s:plugconf) :
  \           type(a:1) is v:t_list ? a:1 : [a:1]
    if has_key(s:plugconf, path) &&
    \  has_key(s:plugconf[path], a:event)
      call call(s:plugconf[path][a:event], [])
    endif
  endfor
endfunction

function! s:rtp_has(path) abort
  let paths = map(split(&rtp, ','), 'expand(v:val)')
  return index(paths, expand(a:path)) isnot -1
endfunction

function! s:get_last_transacted_repos(lock_json) abort
  return filter(copy(a:lock_json.repos), 'v:val.trx_id is a:lock_json.trx_id')
endfunction

function! s:read_lock_json() abort
  let [lines, err] = s:readfile(s:Path.lock_json(), 'b')
  if err isnot s:NIL
    return [v:null, err]
  endif
  let [lock_json, err] = s:json_decode(join(lines, ''))
  if err isnot s:NIL
    return [v:null, err]
  endif
  return [lock_json, s:NIL]
endfunction

function! s:__err_to_values(fn, args) abort
  try
    return [call(a:fn, a:args), s:NIL]
  catch
    return [v:null, s:new_error()]
  endtry
endfunction

function! s:new_error() abort
  return {'msg': v:exception, 'stacktrace': v:throwpoint}
endfunction

function! s:readfile(...) abort
  return s:__err_to_values('readfile', a:000)
endfunction

function! s:json_decode(...) abort
  return s:__err_to_values('json_decode', a:000)
endfunction

function! s:msg_cmdline(msg) abort
  echohl ErrorMsg
  echomsg a:msg
  echohl None
endfunction

function! s:msg_buffer(msg) abort
  let msg_list = split(a:msg, '\n', 1)
  call s:open_msg_buffer(len(msg_list) + 2)
  if bufname('') isnot s:VOLT_MSG_BUFNAME
    call s:msg_cmdline('Could not open volt msg buffer')
    return
  endif
  setlocal noreadonly modifiable
  try
    call setline(line('$'), msg_list)
  finally
    setlocal readonly nomodifiable
  endtry
endfunction

function! s:open_msg_buffer(height) abort
  " Find error buffer and switch to the window if it exists
  for bufnr in tabpagebuflist()
    if bufname(bufnr) is s:VOLT_MSG_BUFNAME
      execute bufwinnr(bufnr) 'wincmd w'
      return
    endif
  endfor

  " Open error buffer if it does not exist
  execute 'botright' max([a:height, 1]) 'new'
  file `=s:VOLT_MSG_BUFNAME`
  setlocal buftype=nofile readonly modifiable
endfunction


let s:Path = {}

function! s:Path.volt_cmd() abort
  return s:Path.join(s:Path.volt_path(), 'bin', 'volt')
endfunction

function! s:Path.volt_path() abort
  if $VOLT_PATH isnot ''
    return $VOLT_PATH
  endif
  let home = $HOME
  if home is ''
    let home = $APPDATA
    if home is ''
      throw 'Couldn''t look up VOLTPATH'
    endif
  endif
  return s:Path.join(home, 'volt')
endfunction

function! s:Path.lock_json() abort
  return s:Path.join(s:Path.volt_path(), 'lock.json')
endfunction

function! s:Path.join(...) abort
  return join(a:000, s:PATH_SEP)
endfunction

function! s:Path.full_repos_path_of(repos_path) abort
  return s:Path.join(s:Path.volt_path(), 'repos', a:repos_path)
endfunction

function! s:Path.plugconf_of(repos_path) abort
  return s:Path.join(s:Path.volt_path(), 'plugconf', a:repos_path)
endfunction
