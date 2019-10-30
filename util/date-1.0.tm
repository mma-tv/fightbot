namespace eval ::util {
    namespace export tz timeDiff toGMT toLocal now currentYear timezone\
        formatShortDate formatDateTime formatWordDate formatWordDateTime

    variable tz ":America/New_York"  ;# "-0500"
    if {[catch {clock scan 0 -timezone $tz}]} {
        set ::util::tz "-0500"
    }
}

proc ::util::tz {} {
    variable tz
    return $tz
}

# Some sort of Eggdrop/TCL bug results in clock changes not updating properly,
# so we anchor at [unixtime] to be safe

proc ::util::timeDiff {date1 {future "away"} {past "ago"}} {
    set secs [expr [clock scan $date1 -base [unixtime] -gmt 1] - [unixtime]]
    set rel  [expr {$secs < 0 ? $past : $future}]
    set secs [expr abs($secs)]
    set days [expr $secs / (60 * 60 * 24)]
    set secs [expr {$days ? 0 : $secs % (60 * 60 * 24)}]
    set hrs  [expr $secs / (60 * 60)]
    set secs [expr $secs % (60 * 60)]
    set mins [expr $secs / 60]
    set secs [expr {($hrs || $mins) ? 0 : $secs % 60}]
    foreach {value unit} [list $days d $hrs h $mins m $secs s] {
        if {$value > 0} {
            append text "$value$unit "
        }
    }
    return [expr {[info exists text] ? "$text$rel" : "NOW"}]
}

proc ::util::toGMT {{date ""}} {
    return [clock format [clock scan $date -base [unixtime] -timezone [tz]] -format "%Y-%m-%d %H:%M:%S" -gmt 1]
}

proc ::util::toLocal {{date ""}} {
    return [clock format [clock scan $date -base [unixtime] -gmt 1] -format "%Y-%m-%d %H:%M:%S" -timezone [tz]]
}

proc ::util::now {{gmt 1}} {
    return [expr {$gmt ? [toGMT] : [toLocal]}]
}

proc ::util::currentYear {} {
    return [clock format [unixtime] -format "%Y" -timezone [tz]]
}

proc ::util::timezone {{withOffset 0}} {
    return [clock format [unixtime] -format "%Z[expr {$withOffset ? " %z" : ""}]" -timezone [tz]]
}

proc ::util::validTimeZone {tz} {
    set timezones {
        gmt ut utc bst wet wat at nft nst ndt ast adt est edt cst cdt mst mdt
        pst pdt yst ydt hst hdt cat ahst nt idlw cet cest met mewt mest swt
        sst eet eest bt it zp4 zp5 ist zp6 wast wadt jt cct jst cast cadt
        east eadt gst nzt nzst nzdt idle
    }
    return [expr {[lsearch -exact $timezones $tz] != -1}]
}

proc ::util::wordDay {day} {
    if {[regexp {^\d+$} $day]} {
        if {$day < 11 || $day > 13} {
            switch [string index $day end] {
                1 { return "${day}st" }
                2 { return "${day}nd" }
                3 { return "${day}rd" }
            }
        }
        return "${day}th"
    }
    return $day
}

proc ::util::shortYear {utime format} {
    if {[clock format [unixtime] -format "%Y" -timezone [tz]] == [clock format $utime -format "%Y" -timezone [tz]]} {
        return ""
    }
    return $format
}

proc ::util::formatShortDate {datetime} {
    set dt [clock scan $datetime -base [unixtime] -gmt 1]
    return [string trimleft [clock format $dt -format "%m/%d[shortYear $dt "/%y"]" -timezone [tz]] 0]
}

proc ::util::formatDateTime {datetime} {
    set dt [clock scan $datetime -base [unixtime] -gmt 1]
    regsub -all {\s{2,}} [clock format $dt -format "%m/%d[shortYear $dt "/%Y"] %l:%M%P" -timezone [tz]] " " date
    return [string trimleft $date 0]
}

proc ::util::formatWordDate {datetime {formal 1}} {
    set dt [clock scan $datetime -base [unixtime] -gmt 1]
    set date [clock format $dt -format "%b %e[shortYear $dt ", %Y"]" -timezone [tz]]
    return "[lindex $date 0] [expr {$formal ? [wordDay [lrange $date 1 end]] : [lrange $date 1 end]}]"
}

proc ::util::formatWordDateTime {datetime {formal 1}} {
    set dt [clock scan $datetime -base [unixtime] -gmt 1]
    set date [clock format $dt -format "%a, %b %e[shortYear $dt ", %Y"] at %l:%M%P" -timezone [tz]]
    regsub {:00} $date "" date
    return "[lrange $date 0 1] [expr {$formal ? [wordDay [lindex $date 2]] : [lindex $date 2]}] [lrange $date 3 end]"
}
