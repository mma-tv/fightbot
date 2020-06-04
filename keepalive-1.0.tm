namespace eval ::keepalive {}
namespace eval ::keepalive::v {
  variable frequency 1 ;# minute
  variable logLevel  7
  variable message   "###KEEP-ALIVE###"
}

proc ::keepalive::start {} {
  stop
  timer $v::frequency [list putloglev $v::logLevel * $v::message] 0
}

proc ::keepalive::stop {} {
  foreach timer [timers] {
    if {[string match "*$v::message" [lindex $timer 1]]} {
      killtimer [lindex $timer 2]
    }
  }
}
