namespace eval ::keepalive {}
namespace eval ::keepalive::v {
  variable frequency 1 ;# minute
  variable logLevel  7
  variable message   "###KEEP-ALIVE###"
  variable timerId
}

proc ::keepalive::start {} {
  stop
  set v::timerId [timer $v::frequency [list putloglev $v::logLevel * $v::message] 0]
}

proc ::keepalive::stop {} {
  catch {killtimer $v::timerId}
}
