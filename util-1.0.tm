####################################################################
#
# Module: util.tm
# Author: makk@EFnet
# Description: Utility library of common functions
#
####################################################################

namespace eval ::util {
    namespace export loadDatabase s populate put putMessage putNotice\
        putAction mbind logStackable bindSQL scheduleBackup registerCleanup

    variable ns [namespace current]
    variable maxMessageLen 510
    variable maxLineWrap   5  ;# max lines to wrap when text is too long
    variable floodExempt   1  ;# set to 1 if the bot is exempt from flood limits
    variable floodSupport  0
}

proc ::util::loadDatabase {db database {sqlScripts {}}} {
    global tcl_platform
    variable ns

    foreach item [concat $database $sqlScripts] {
        catch {exec chmod 600 $item}
    }

    if {[catch {
        if {$tcl_platform(platform) eq "unix"} {
            load "[pwd]/tclsqlite3.so" "tclsqlite3"
        } else {
            load "[pwd]/tclsqlite3.dll" "tclsqlite3"
        }
        sqlite3 $db $database
    } error]} {
        return -code error "*** Failed to open database '$database': $error"
    }

    foreach script $sqlScripts {
        if {[catch {set f [open $script r]} error]} {
            return -code error "*** Failed to open SQL script '$script': $error"
        } else {
            catch {$db eval [read $f]}
            catch {close $f}
        }
    }

    catch {$db function REGEXP ${ns}::regexpSQL}
    return 1
}

proc ::util::s {quantity {suffix "s"}} {
    return [expr {$quantity == 1 ? "" : $suffix}]
}

proc ::util::regexpSQL {expr text} {
    if {[catch {set ret [regexp -nocase -- $expr $text]}]} {
        # invalid expression
        return 0
    }
    return $ret
}

# add list placeholder support - ex: db eval [populate {SELECT * FROM t WHERE u IN(::var)}]
proc ::util::populate {sql} {
    set s ""
    set pos 0
    foreach {first last} [join [regexp -all -indices -inline {::[\w$]+} $sql]] {
        append s [string range $sql $pos [expr $first - 1]]
        set var [string range $sql [expr $first + 2] $last]
        upvar $var list
        if {[info exists list]} {
            set varName "${var}$"
            upvar $varName a
            array unset a *
            set items {}
            set i 0
            foreach item $list {
                set a($i) $item
                lappend items ":${varName}($i)"
                incr i
            }
            append s [join $items ,]
        } else {
            append s "NULL"
        }
        set pos [expr $last + 1]
    }
    return [append s [string range $sql $pos end]]
}

proc ::util::log {loglevel text} {
    if {$loglevel >= 1 && $loglevel <= 8} {
        return [putloglev $loglevel * $text]
    }
    return
}

proc ::util::logStackable {unick host handle dest text} {
    if {$unick == $dest} {
        putcmdlog "($unick!$host) !$handle! $text"
    } else {
        putcmdlog "<<$unick>> !$handle! $text"
    }
    return 1
}

proc ::util::initCapabilities {from keyword text} {
    variable floodSupport 0
    return 0
}
bind raw - 001 ::util::initCapabilities

proc ::util::capabilities {from keyword text} {
    variable floodSupport
    if {[lsearch -exact [split $text] "CPRIVMSG"] >= 0} {
        set floodSupport 1
    }
    return 0
}
bind raw - 005 ::util::capabilities

if {[catch {package require eggdrop 1.6.20}]} {
    proc ::putnow {text args} {
        append text "\r\n"
        return [putdccraw 0 [string length $text] $text]
    }
}

proc ::util::put {text {queue putquick} {loglevel 0} {prefix ""} {suffix ""} {ellipsis "..."}} {
    global botname
    variable maxMessageLen
    variable maxLineWrap

    set maxText [expr $maxMessageLen - [string length $botname]\
        - [string length $prefix] - [string length $suffix] - 2]

    set overflow [expr {$maxText < [string length $text]}]
    if {$overflow} {
        incr maxText -[string length $ellipsis]
    }

    set lines 0
    set l [string length $text]
    for {set i 0} {$i < $l && $lines < $maxLineWrap} {incr i $maxText} {
        set message [string range $text $i [expr $i + $maxText - 1]]
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

proc ::util::putType {type unick dest text {queue putquick} {loglevel 0}} {
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

proc ::util::putMessage {unick dest text {queue putquick} {loglevel 0}} {
    return [putType "PRIVMSG" $unick $dest $text $queue $loglevel]
}

proc ::util::putNotice {unick dest text {queue putquick} {loglevel 0}} {
    return [putType "NOTICE" $unick $dest $text $queue $loglevel]
}

proc ::util::putAction {unick dest text {queue putquick} {loglevel 0}} {
    return [put $text $queue $loglevel "PRIVMSG $unick :\001ACTION found " "\001"]
}

proc ::util::redirect {handler unick host handle text} {
    if {[llength $handler] == 1} {
        return [$handler $unick $host $handle $unick $text]
    }
    return [[lindex $handler 0] [lrange $handler 1 end] $unick $host $handle $unick $text]
}

proc ::util::mbind {types flags triggers handler} {
    variable ns

    set totalBinds 0
    set msgHandler [list ${ns}::redirect $handler]

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

# for database maintenance - use with caution!
proc ::util::sql {command db handle idx query} {
    putcmdlog "#$handle# $command $query"
    if {[catch {$db eval $query row {
        set results {}
        foreach field $row(*) {
            lappend results "\002$field\002($row($field))"
        }
        putdcc $idx [join $results]
    }} error]} {
        putdcc $idx "*** SQL query failed: $error"
    }
    return 0
}

proc ::util::bindSQL {command db {flags "n"}} {
    variable ns
    return [bind dcc $flags $command [list ${ns}::sql $command $db]]
}

proc ::util::backup {db dbFile loglevel minute hour day month year} {
    set backupFile "$dbFile.bak"
    log $loglevel "Backing up $dbFile database to $backupFile..."
    catch {
        $db backup $backupFile
        exec chmod 600 $backupFile
    }
    return
}

proc ::util::scheduleBackup {db dbFile {when "04:00"} {loglevel 0}} {
    variable ns
    set when [split $when ":"]
    set hour [lindex $when 0]
    set minute [lindex $when 1]
    return [bind time - "$minute $hour * * *" [list ${ns}::backup $db $dbFile $loglevel]]
}

proc ::util::cleanup {nsRef db type} {
    foreach bind [binds "*${nsRef}::*"] {
        foreach {type flags command {} handler} $bind {
            catch {unbind $type $flags $command $handler}
        }
    }
    catch {$db close}
    namespace delete $nsRef
    return
}

proc ::util::registerCleanup {nsRef db} {
    variable ns
    return [bind evnt - prerehash [list ${ns}::cleanup $nsRef $db]]
}
