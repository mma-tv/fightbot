package require tcltest

namespace eval ::tcltestx {
namespace export capture

oo::class create ChannelIntercept {
  variable buffer

  method initialize {handle mode} {
    if {$mode ne "write"} {error "can't handle reading"}
    return {finalize initialize write}
  }
  method finalize {handle} {
  }
  method write {handle bytes} {
    append buffer $bytes
    return ""
  }
  method buffer {} {
    return $buffer
  }
}

proc capture {channel lambda} {
  set interceptor [ChannelIntercept new]
  chan push $channel $interceptor
  apply [list x $lambda] {}
  chan pop $channel
  return [$interceptor buffer]
}

proc globNoCase {expected actual} {
  return [string match -nocase $expected $actual]
}
::tcltest::customMatch globNoCase [namespace current]::globNoCase

}
