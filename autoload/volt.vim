scriptencoding utf-8

let s:IS_WIN = has('win16') || has('win32')
\               || has('win64') || has('win95')
let s:PATH_SEP = s:IS_WIN ? '\' : '/'
let s:VOLT_MSG_BUFNAME = '[VOLT_MSG]'
let s:NIL = []
lockvar! s:NIL
let s:REPO_DIR = expand('<sfile>:h:h')
let s:MSG_BUF_HEIGHT = 7
let s:VOLT_CMD_VERSION = 'v0.0.0-alpha'

let s:volt_repos = {}

if !hlexists('VoltInfoMsg')
  highlight VoltInfoMsg term=bold ctermfg=Cyan guifg=#80a0ff gui=bold
endif

function! volt#load(...) abort
  let msg = s:new_msg()
  call msg.close_buffer()
  redraw

  if a:0 && type(a:1) is# v:t_string
    let err = s:load_plugin(a:1)
    if err isnot# s:NIL
      call msg.buffer('[ERROR] Could not load plugin: ' . a:1)
      call msg.buffer('[ERROR] ' . err.msg)
      if err.stacktrace isnot# ''
        call msg.buffer('[ERROR] Stacktrace: ' . err.stacktrace)
      endif
      return 0
    endif
    return 1
  endif

  let err = s:load_all(msg)
  if err isnot# s:NIL
    echomsg '[ERROR]' err.msg
    if err.stacktrace isnot# ''
      echomsg '[ERROR] Stacktrace:' err.stacktrace
    endif
    return 0
  endif
  return 1
endfunction

function! s:load_plugin(repos_path) abort
  let [repos, err] = s:read_repos_of(a:repos_path)
  if err isnot# s:NIL
    return err
  endif
  let new_rtp = split(&rtp, ',')
  let fullpath = s:Path.full_repos_path_of(repos.path)
  if index(new_rtp, fullpath) isnot# -1
    let new_rtp += [fullpath]
    let &rtp = join(new_rtp, ',')
  endif
  return s:NIL
endfunction

function! s:read_repos_of(repos_path) abort
  let [json, err] = s:read_lock_json()
  if err isnot# s:NIL
    return [v:null, s:new_error('could not read lock.json: ' . err.msg)]
  endif
  for repos in json.repos
    if repos.path is# a:repos_path
      return [repos, s:NIL]
    endif
  endfor
  return [v:null, s:new_error('repos not found: ' . a:repos_path)]
endfunction

function! s:load_all(msg) abort
  " Check if $VOLTPATH exists
  let volt_path = s:Path.volt_path()
  if !isdirectory(volt_path)
    return s:new_error('VOLTPATH directory does not exist: ' . volt_path)
  endif

  " Get active profile repos list
  let [profile, err] = s:get_active_profile()
  if err isnot# s:NIL
    return err
  endif

  " Load init.vim
  let init_vim = s:Path.init_vim()
  if filereadable(init_vim)
    try
      source `=init_vim`
    catch
      call a:msg.buffer('[WARN] Error occurred while reading init.vim')
      call a:msg.buffer('[WARN] Error: ' . v:exception)
      call a:msg.buffer('[WARN] Stacktrace: ' . v:throwpoint)
    endtry
  endif

  " Add plugins to runtimepath
  let new_rtp = split(&rtp, ',')
  for repos in profile.repos
    let fullpath = s:Path.full_repos_path_of(repos.path)
    if !s:rtp_has(fullpath, new_rtp)
      let new_rtp += [fullpath]
    endif
  endfor
  let &rtp = join(new_rtp, ',')

  " Load plugconf
  for repos in profile.repos
    let plugconf = s:Path.plugconf_of(repos)
    if filereadable(plugconf)
      try
        source `=plugconf`
      catch
        call a:msg.buffer('[WARN] Error occurred while reading plugconf of ' . repos)
        call a:msg.buffer('[WARN] Error: ' . v:exception)
        call a:msg.buffer('[WARN] Stacktrace: ' . v:throwpoint)
      endtry
    endif
  endfor

  return s:NIL
endfunction

function! s:get_active_profile() abort
  let [json, err] = s:read_lock_json()
  if err isnot# s:NIL
    return [v:null, s:new_error('could not read lock.json: ' . err.msg)]
  endif
  if json.active_profile is# 'default'
    return [{
    \ 'load_init': json.load_init,
    \ 'repos': json.repos,
    \}, s:NIL]
  else
    let profiles = filter(copy(json.profiles),
    \                     {_,profile -> profile.name is# json.active_profile})
    if empty(profiles)
      let err = s:new_error(printf('no profile ''%s'' found', json.active_profile))
      return [v:null, err]
    endif
    let repos_list = []
    for path in profiles[0].repos_path
      let repos = s:NIL
      for r in json.repos
        if r.path is# path
          let repos = r
          break
        endif
      endfor
      if repos is# s:NIL
        return [v:null, s:new_error('lock.json is broken. not found repos of: ' . path)]
      endif
      let repos_list += [repos]
    endfor
    return [{
    \ 'load_init': profiles[0].load_init,
    \ 'repos': repos_list,
    \}, s:NIL]
  endif
endfunction

function! volt#loaded(repos_path) abort
  return has_key(s:volt_repos, a:repos_path)
endfunction

function! volt#get(args) abort
  let msg = s:new_msg()
  call msg.close_buffer()
  redraw

  " Get volt command fullpath
  let volt_cmd = s:Path.volt_cmd()

  " Install volt command if it does not exist
  if !s:install_volt_cmd(volt_cmd, msg)
    return
  endif

  " Run 'volt get ...'
  let has_error = s:volt_exec({'volt_cmd': volt_cmd, 'cmd': 'get', 'args': a:args}, msg)[1]
  if has_error
    return
  endif

  let [json, err] = s:read_lock_json()
  if err isnot# s:NIL
    call msg.buffer('[ERROR] Could not read lock.json: ' . err.msg)
    return
  endif
  for repos in s:get_last_transacted_repos(json)
    let fullpath = s:Path.full_repos_path_of(repos.path)
    " Append repos path to &rtp if it does not exist
    if !s:rtp_has(fullpath, &rtp)
      let &rtp .= ',' . fullpath
      for file in glob(fullpath . '/plugin/**/*.vim', 1, 1)
        try
          source `=file`
        catch
          call msg.buffer('[WARN] Error occurred while reading ' . file)
          call msg.buffer('[WARN] Error: ' . v:exception)
          call msg.buffer('[WARN] Stacktrace: ' . v:throwpoint)
        endtry
      endfor
    endif
    " helptags
    let docdir = s:Path.join(fullpath, 'doc')
    if isdirectory(docdir)
      helptags `=docdir`
    endif
    " Source plugconf
    let plugconf = s:Path.plugconf_of(repos.path)
    if filereadable(plugconf)
      try
        source `=plugconf`
      catch
        call msg.buffer('[WARN] Error occurred while reading ' . plugconf)
        call msg.buffer('[WARN] Error: ' . v:exception)
        call msg.buffer('[WARN] Stacktrace: ' . v:throwpoint)
      endtry
    endif
    " Run hook_post_update hooks
    call s:run_hooks('hook_post_update', repos.path)
  endfor
endfunction

function! s:rtp_has(path, rtp) abort
  if type(a:rtp) is# v:t_string
    let rtplist = split(a:rtp, ',')
  else
    let rtplist = a:rtp
  endif
  let paths = map(rtplist, 'expand(v:val)')
  return index(paths, expand(a:path)) isnot# -1
endfunction

" Get last transacted (installed, updated, ...) vim plugins:
" compare trx_id and repos[]/trx_id and get matched repos[]/path
function! s:get_last_transacted_repos(json) abort
  return filter(copy(a:json.repos), {_,repos -> repos.trx_id is# a:json.trx_id })
endfunction

function! volt#rm(args) abort
  let msg = s:new_msg()
  call msg.close_buffer()
  redraw

  let [json, err] = s:read_lock_json()
  if err isnot# s:NIL
    call msg.buffer('[ERROR] Could not read lock.json: ' . err.msg)
    return
  endif

  " Get volt command fullpath
  let volt_cmd = s:Path.volt_cmd()

  " Install volt command if it does not exist
  if !s:install_volt_cmd(volt_cmd, msg)
    return
  endif

  " Run 'volt rm ...'
  let has_error = s:volt_exec({'volt_cmd': volt_cmd, 'cmd': 'rm', 'args': a:args}, msg)[1]
  if has_error
    return
  endif

  let [updated_json, err] = s:read_lock_json()
  if err isnot# s:NIL
    call msg.buffer('[ERROR] Could not read updated lock.json: ' . err.msg)
    return
  endif

  let new_rtp = split(&rtp, ',')
  for repos in s:get_removed_repos(json, updated_json)
    let fullpath = s:Path.full_repos_path_of(repos.path)
    call filter(new_rtp, {_,p -> expand(p) isnot# fullpath})
  endfor
  let &rtp = join(new_rtp, ',')
endfunction

function! s:get_removed_repos(json, updated_json) abort
  let json_repos = deepcopy(a:json.repos)
  " Assumption: json_repos contains updated_json.repos
  for repos in a:updated_json.repos
    call filter(json_repos, {_,r -> r.path isnot# repos.path})
  endfor
  return json_repos
endfunction

function! volt#query(args) abort
  let msg = s:new_msg()
  call msg.close_buffer()
  redraw

  " Get volt command fullpath
  let volt_cmd = s:Path.volt_cmd()

  " Install volt command if it does not exist
  if !s:install_volt_cmd(volt_cmd, msg)
    return
  endif

  " Run 'volt query ...'
  let [out, has_error] = s:volt_exec({'volt_cmd': volt_cmd, 'cmd': 'query', 'args': a:args}, msg)
  if !has_error && out !~# '\S'
    call msg.cmdline('[INFO] No output.', 'VoltInfoMsg', 0)
  endif
endfunction

function! volt#profile(args) abort
  let msg = s:new_msg()
  call msg.close_buffer()
  redraw

  " Get volt command fullpath
  let volt_cmd = s:Path.volt_cmd()

  " Install volt command if it does not exist
  if !s:install_volt_cmd(volt_cmd, msg)
    return
  endif

  " Run 'volt profile ...'
  call s:volt_exec({'volt_cmd': volt_cmd, 'cmd': 'profile', 'args': a:args}, msg)
endfunction

function! s:run_hooks(event, ...) abort
  for path in a:0 is# 0 ? keys(s:volt_repos) :
  \           type(a:1) is# v:t_list ? a:1 : [a:1]
    if has_key(s:volt_repos, path) &&
    \  has_key(s:volt_repos[path], 'plugconf') &&
    \  has_key(s:volt_repos[path].plugconf, a:event)
      call call(s:volt_repos[path].plugconf[a:event], [])
    endif
  endfor
endfunction

function! s:volt_exec(opts, msg) abort
  let opts = deepcopy(a:opts)
  call extend(opts, {
  \ 'show_buffer': 1,
  \ 'show_cmdline': 1,
  \ 'args': [],
  \}, 'keep')
  if !has_key(opts, 'volt_cmd')
    throw 's:volt_exec(): ''volt_cmd'' is required'
  endif
  if !has_key(opts, 'cmd')
    throw 's:volt_exec(): ''cmd'' is required'
  endif

  let shellargs = join([opts.volt_cmd, opts.cmd] + opts.args)
  if opts.show_cmdline
    call a:msg.cmdline(printf('[INFO] Running ''%s''', shellargs), 'VoltInfoMsg')
  endif
  let out = system(shellargs)
  let has_error = !!v:shell_error
  if opts.show_buffer
    for line in (out =~# '\S' ? split(out, '\n', 1) : [])
      if line =~# '\S'
        call a:msg.buffer(line)
      endif
    endfor
  endif
  return [out, has_error]
endfunction

function! s:install_volt_cmd(volt_cmd, msg) abort
  let opts = {
  \ 'volt_cmd': a:volt_cmd,
  \ 'cmd': 'version',
  \ 'show_buffer': 0,
  \ 'show_cmdline': 0,
  \}
  if getfperm(a:volt_cmd) !~# '^..x' ||
  \   s:volt_exec(opts, a:msg)[0] !~# 'volt ' . s:VOLT_CMD_VERSION
    call a:msg.cmdline('[INFO] Invoking bootstrap.vim ...', 'VoltInfoMsg')
    let $VOLT_NOGUIDE = '1'
    try
      source `=s:REPO_DIR . '/bootstrap.vim'`
    catch
      call a:msg.buffer('[ERROR] ' . v:exception . "\n" . v:throwpoint)
      return 0
    endtry
  endif
  return 1
endfunction

function! s:read_lock_json() abort
  let [lines, err] = s:readfile(s:Path.lock_json(), 'b')
  if err isnot# s:NIL
    return [v:null, err]
  endif
  let [json, err] = s:json_decode(join(lines, ''))
  if err isnot# s:NIL
    return [v:null, err]
  endif
  return [json, s:NIL]
endfunction

function! s:__err_to_values(fn, args) abort
  try
    return [call(a:fn, a:args), s:NIL]
  catch
    return [v:null, s:new_error()]
  endtry
endfunction

function! s:new_error(...) abort
  if a:0
    return {'msg': a:1, 'stacktrace': ''}
  endif
  return {'msg': v:exception, 'stacktrace': v:throwpoint}
endfunction

function! s:readfile(...) abort
  return s:__err_to_values('readfile', a:000)
endfunction

function! s:json_decode(...) abort
  return s:__err_to_values('json_decode', a:000)
endfunction

let s:Msg = {}

let s:msg_id = 1

function! s:new_msg() abort
  let msg = deepcopy(s:Msg)
  let s:msg_id += 1
  let msg._msg_id = s:msg_id
  return msg
endfunction

function! s:Msg.cmdline(msg, hl, ...) abort
  execute 'echohl' a:hl
  let save_hist = get(a:000, 0, 1)
  if save_hist
    echomsg a:msg
  else
    echo a:msg
  endif
  echohl None
endfunction

function! s:Msg.buffer(msg) abort
  let msg_list = split(a:msg, '\n', 1)
  call self._open_buffer(s:MSG_BUF_HEIGHT)
  if bufname('') isnot# s:VOLT_MSG_BUFNAME && has_key(w:, 'volt_msg_id')
    call self.cmdline('Could not open volt msg buffer', 'ErrorMsg')
    return
  endif
  " Show message immediately
  redraw
  " Append messages to the last line
  setlocal noreadonly modifiable
  try
    let is_empty = line('$') is# 1 && getline(1) is# ''
    let lnum = is_empty ? 1 : line('$') + 1
    call setline(lnum, msg_list)
  finally
    setlocal readonly nomodifiable
  endtry
endfunction

function! s:Msg._open_buffer(height) abort
  " Find msg buffer and switch to the window if it exists
  for bufnr in tabpagebuflist()
    if bufname(bufnr) is# s:VOLT_MSG_BUFNAME
      if get(w:, 'volt_msg_id', 0) is# self._msg_id
        execute bufwinnr(bufnr) 'wincmd w'
        return
      else
        " Msg ID is different, find next buffer...
        execute bufwinnr(bufnr) 'wincmd w'
        close
      endif
    endif
  endfor

  " Open error buffer if it does not exist
  execute 'botright' max([a:height, 1]) 'new'
  file `=s:VOLT_MSG_BUFNAME`
  setlocal buftype=nofile readonly modifiable
  setfiletype voltmsg

  " Set msg ID
  let w:volt_msg_id = self._msg_id
endfunction

function! s:Msg.close_buffer() abort
  " Find msg buffer and close the window if it exists
  for bufnr in tabpagebuflist()
    if bufname(bufnr) is# s:VOLT_MSG_BUFNAME
      execute bufwinnr(bufnr) 'wincmd c'
      return
    endif
  endfor
endfunction


let s:Path = {}

function! s:Path.volt_cmd() abort
  return s:Path.join(s:Path.volt_path(), 'bin', 'volt')
endfunction

function! s:Path.volt_path() abort
  if $VOLT_PATH isnot# ''
    return $VOLT_PATH
  endif
  let home = $HOME
  if home is# ''
    let home = $APPDATA
    if home is# ''
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

function! s:Path.init_vim() abort
  return s:Path.join(s:Path.volt_path(), 'rc', 'init.vim')
endfunction
