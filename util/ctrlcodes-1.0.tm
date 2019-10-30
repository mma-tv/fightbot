namespace eval ::util::ctrlcodes {
    namespace export c /c b /b r /r u /u

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
}
