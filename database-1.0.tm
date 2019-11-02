::tcl::tm::path add [file dirname [info script]]

package require log

namespace eval ::database {
    namespace export loadDatabase populate bindSQL scheduleBackup
    namespace import ::log::log
}

proc ::database::loadDatabase {db database {sqlScripts {}}} {
    global tcl_platform

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

    catch {$db function REGEXP ::database::regexpSQL}
    return 1
}

proc ::database::regexpSQL {expr text} {
    if {[catch {set ret [regexp -nocase -- $expr $text]}]} {
        # invalid expression
        return 0
    }
    return $ret
}

# add list placeholder support - ex: db eval [populate {SELECT * FROM t WHERE u IN(::var)}]
proc ::database::populate {sql} {
    set s ""
    set pos 0
    foreach {first last} [join [regexp -all -indices -inline {::[\w$]+} $sql]] {
        append s [string range $sql $pos [expr {$first - 1}]]
        set var [string range $sql [expr {$first + 2}] $last]
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
        set pos [expr {$last + 1}]
    }
    return [append s [string range $sql $pos end]]
}

# for database maintenance - use with caution!
proc ::database::sql {command db handle idx query} {
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

proc ::database::bindSQL {command db {flags "n"}} {
    return [bind dcc $flags $command [list ::database::sql $command $db]]
}

proc ::database::backup {db dbFile loglevel minute hour day month year} {
    set backupFile "$dbFile.bak"
    log $loglevel "Backing up $dbFile database to $backupFile..."
    catch {
        $db backup $backupFile
        exec chmod 600 $backupFile
    }
    return
}

proc ::database::scheduleBackup {db dbFile {when "04:00"} {loglevel 0}} {
    set when [split $when ":"]
    set hour [lindex $when 0]
    set minute [lindex $when 1]
    return [bind time - "$minute $hour * * *" [list ::database::backup $db $dbFile $loglevel]]
}
