foreach var {botnick botname} {
  if {![info exists $var]} {
    set ::$var $var
  }
}

foreach cmd {
  bind unixtime putlog putloglev putcmdlog putdcc
  putserv puthelp putquick putnow isop isvoice
} {
  if {[info commands $cmd] eq ""} {
    switch -glob -- $cmd {
      bind { proc ::$cmd {args} {} }
      unixtime { proc ::$cmd {} { return [clock seconds] } }
      putlog* - putcmdlog { proc ::$cmd {args} {} }
      put* { proc ::$cmd {args} { puts [join $args] } }
      isop - isvoice { proc ::$cmd {args} { return [expr {rand() < .5 ? 1 : 0}] } }
      default { proc ::$cmd {args} {} }
    }
  }
}
