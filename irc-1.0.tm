package require log
package require formatter

namespace eval ::irc {
    namespace export put putMessage putNotice putAction msg send msend mpost mbind
    namespace import ::log::log ::formatter::s

    variable putCommand putnow  ;# send function: putnow, putquick, putserv, puthelp
    variable debugLogLevel   8  ;# log all output to this log level [1-8, 0 = disabled]
    variable maxMessageLen 510
    variable maxLineWrap     5  ;# max lines to wrap when text is too long
    variable floodExempt     1  ;# set to 1 if the bot is exempt from flood limits
    variable floodSupport    0
}

proc ::irc::initCapabilities {from keyword text} {
    variable floodSupport 0
    return 0
}
bind raw - 001 ::irc::initCapabilities

proc ::irc::capabilities {from keyword text} {
    variable floodSupport
    if {[lsearch -exact [split $text] "CPRIVMSG"] >= 0} {
        set floodSupport 1
    }
    return 0
}
bind raw - 005 ::irc::capabilities

proc ::irc::put {text {queue putquick} {loglevel 0} {prefix ""} {suffix ""} {ellipsis "..."}} {
    global botname
    variable maxMessageLen
    variable maxLineWrap

    set maxText [expr {$maxMessageLen - [string length $botname]\
        - [string length $prefix] - [string length $suffix] - 2}]

    set overflow [expr {$maxText < [string length $text]}]
    if {$overflow} {
        incr maxText -[string length $ellipsis]
    }

    set lines 0
    set l [string length $text]
    for {set i 0} {$i < $l && $lines < $maxLineWrap} {incr i $maxText} {
        set message [string range $text $i [expr {$i + $maxText - 1}]]
        if {$overflow} {
            set message [expr {$i ? "$ellipsis$message" : "$message$ellipsis"}]
        }
        log $loglevel "\[>\] $prefix$message$suffix"
        $queue "$prefix$message$suffix"
        incr lines
    }
    if {[string length [string range $text $i end]]} {
        $queue "$prefix\[ Message truncated to $maxLineWrap line[s $maxLineWrap]. \]$suffix"
    }
    return 0
}

proc ::irc::putType {type unick dest text {queue putquick} {loglevel 0}} {
    global botnick
    variable floodExempt
    variable floodSupport

    if {![info exists floodExempt] || !$floodExempt} {
        if {$floodSupport} {
            foreach chan [concat [list $dest] [channels]] {
                if {[validchan $chan] && [isop $botnick $chan] && [onchan $unick $chan]} {
                    return [put $text $queue $loglevel "C$type $unick $chan :"]
                }
            }
        }
        if {[string index $dest 0] ne "#" && $queue eq "putnow"} {
            set queue putquick
        }
    }
    return [put $text $queue $loglevel "$type $unick :"]
}

proc ::irc::putMessage {unick dest text {queue putquick} {loglevel 0}} {
    return [putType "PRIVMSG" $unick $dest $text $queue $loglevel]
}

proc ::irc::putNotice {unick dest text {queue putquick} {loglevel 0}} {
    return [putType "NOTICE" $unick $dest $text $queue $loglevel]
}

proc ::irc::putAction {unick dest text {queue putquick} {loglevel 0}} {
    return [put $text $queue $loglevel "PRIVMSG $unick :\001ACTION found " "\001"]
}

proc ::irc::msg {target text} {
    variable putCommand
    variable debugLogLevel
    return [putMessage $target $target $text $putCommand $debugLogLevel]
}

proc ::irc::send {unick dest text} {
    variable putCommand
    variable debugLogLevel
    if {$dest ne ""} {
        if {$unick eq $dest} {
            set put putMessage
        } else {
            set put putNotice
        }
        return [$put $unick $dest $text $putCommand $debugLogLevel]
    }
    return
}

proc ::irc::msend {unick dest lines} {
    foreach line $lines {
        send $unick $dest $line
    }
}

proc ::irc::mpost {dest lines} {
  foreach line $lines {
    msg $dest $line
  }
}

proc ::irc::redirect {handler unick host handle text} {
    if {[llength $handler] == 1} {
        return [$handler $unick $host $handle $unick $text]
    }
    return [[lindex $handler 0] [lrange $handler 1 end] $unick $host $handle $unick $text]
}

proc ::irc::mbind {types flags triggers handler} {
    set totalBinds 0
    set msgHandler [list [namespace current]::redirect $handler]

    foreach type $types {
        set eventHandler $handler
        if {$type eq "msg" || $type eq "msgm"} {
            set eventHandler $msgHandler
        }
        foreach trigger $triggers {
            if {$type eq "msgm" && [llength $trigger] > 1} {
                set trigger [lrange [split $trigger] 1 end]
            }
            bind $type $flags $trigger $eventHandler
            incr totalBinds
        }
    }
    return $totalBinds
}
