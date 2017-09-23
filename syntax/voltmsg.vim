syntax match voltmsgError /^\[ERROR\]/
syntax match voltmsgWarn /^\[WARN\]/
syntax match voltmsgInfo /^\[INFO\]/

hi def link voltmsgError ErrorMsg
hi def link voltmsgWarn WarningMsg
hi def link voltmsgInfo VoltInfoMsg

let b:current_syntax = "voltmsg"
