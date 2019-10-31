namespace eval ::log {
    namespace export log logStackable
}

proc ::log::log {loglevel text} {
    if {$loglevel >= 1 && $loglevel <= 8} {
        return [putloglev $loglevel * $text]
    }
    return
}

proc ::log::logStackable {unick host handle dest text} {
    if {$unick == $dest} {
        putcmdlog "($unick!$host) !$handle! $text"
    } else {
        putcmdlog "<<$unick>> !$handle! $text"
    }
    return 1
}
