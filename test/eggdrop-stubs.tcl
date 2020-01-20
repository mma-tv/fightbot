foreach var {botnick botname} {
  if {![info exists $var]} {
    set ::$var $var
  }
}

foreach cmd {
  bind unixtime putlog putloglev putcmdlog putdcc
  putserv puthelp putquick putnow isop isvoice matchattr
} {
  if {[info commands $cmd] eq ""} {
    switch -glob -- $cmd {
      bind { proc ::$cmd {args} {} }
      unixtime { proc ::$cmd {} { return [clock seconds] } }
      putlog* - putcmdlog { proc ::$cmd {args} {} }
      put* { proc ::$cmd {args} { puts [join $args] } }
      matchattr - isop - isvoice {
        proc ::$cmd {u args} {
          return [string match "*[namespace tail [lindex [info level 0] 0]]" $u]
        }
      }
      default { proc ::$cmd {args} {} }
    }
  }
}
