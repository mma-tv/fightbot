namespace eval ::util::ctrlcodes {
    namespace export c /c b /b r /r u /u closeDanglingCtrlCodes

    proc c {color {bgcolor ""}} {
        return "\003$color[expr {$bgcolor eq "" ? "" : ",$bgcolor"}]"
    }
    proc /c {} { return "\003" }
    proc  b {} { return "\002" }
    proc /b {} { return "\002" }
    proc  r {} { return "\026" }
    proc /r {} { return "\026" }
    proc  u {} { return "\037" }
    proc /u {} { return "\037" }

    proc closeDanglingCtrlCodes {str} {
        set s $str
        set matches {}
        foreach c {\002 \003 \026 \037} {
            if {[expr [regexp -all -indices $c $str i] & 1]} {
                lappend matches [lindex $i 0]
            }
        }
        foreach c [lsort -decreasing $matches] {
            append s [string index $str $c]
        }
        return $s
    }
}
