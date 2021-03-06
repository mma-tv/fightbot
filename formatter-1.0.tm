namespace eval ::formatter {
    namespace export tabulate s toSmallCaps
}
namespace eval ::formatter::v {
  variable smallCapsMap {
    a ᴀ b ʙ c ᴄ d ᴅ e ᴇ f ғ g ɢ h ʜ i ɪ j ᴊ k ᴋ l ʟ m ᴍ
    n ɴ o ᴏ p ᴘ q ǫ r ʀ s s t ᴛ u ᴜ v ᴠ w ᴡ x x y ʏ z ᴢ
  }
}

proc ::formatter::tabulate {rows {separator " | "} {maxColSizes {}}} {
    set sizes {}
    set table {}

    foreach row $rows {
        set cols [splitString $row $separator]

        # remove columns that have been given 0 size
        for {set i [expr {[llength $cols] - 1}]} {$i >= 0} {incr i -1} {
            if {[lindex $maxColSizes $i] == 0} {
                set cols [lreplace $cols $i $i]
            }
        }

        set i 0
        foreach col $cols {
            set size [string length $col]
            if {$i >= [llength $sizes]} {
                lappend sizes $size
            } elseif {$size > [lindex $sizes $i]} {
                set sizes [lreplace $sizes $i $i $size]
            }
            incr i
        }
        lappend table $cols
    }

    # column pruning is done, so remove all zero-width column specifiers
    while {[set i [lsearch $maxColSizes 0]] >= 0} {
        set maxColSizes [lreplace $maxColSizes $i $i]
    }

    set columnFormats {}
    set i 0
    foreach size $sizes {
        set max [lindex $maxColSizes $i]
        if {[string is digit -strict $max]} {
            lappend columnFormats "%-[expr {min($size, $max)}].${max}s"
        } else {
            lappend columnFormats "%-${size}s"
        }
        incr i
    }

    set tabulated {}

    foreach cols $table {
        set formatted {}
        set formattedCols [format [join $columnFormats $separator] {*}$cols]
        foreach col [splitString $formattedCols $separator] {
            lappend formatted [closeDanglingCtrlCodes $col]
        }
        lappend tabulated [join $formatted $separator]
    }

    return $tabulated
}

proc ::formatter::splitString {str substr} {
    return [split [string map [list $substr \uffff] $str] \uffff]
}

proc ::formatter::closeDanglingCtrlCodes {str} {
    set s $str
    set matches {}
    foreach c {\002 \003 \026 \037} {
        if {[expr {[regexp -all -indices $c $str i] & 1}]} {
            lappend matches [lindex $i 0]
        }
    }
    foreach c [lsort -decreasing $matches] {
        append s [string index $str $c]
    }
    return $s
}

proc ::formatter::s {quantity {suffix "s"}} {
    return [expr {$quantity == 1 ? "" : $suffix}]
}

proc ::formatter::toSmallCaps {text} {
  return [string map $v::smallCapsMap [string tolower $text]]
}
