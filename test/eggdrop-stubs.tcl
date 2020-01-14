foreach cmd {
  bind unixtime putlog putloglev putdcc
  putserv puthelp putquick putnow isop isvoice
} {
  if {[info commands $cmd] eq ""} {
    switch -glob -- $cmd {
      bind { proc ::bind {args} {} }
      unixtime { proc ::unixtime {} { return [clock seconds] } }
      put* { proc ::$cmd {args} { puts [join $args] } }
      isop - isvoice { proc ::$cmd {args} { return [expr {rand() < .5 ? 1 : 0}] } }
      default { proc ::$cmd {args} {} }
    }
  }
}
