#!/usr/bin/env tclsh

variable cwd [file dirname [info script]]
source [file join $cwd eggdrop-stubs.tcl]
::tcl::tm::path add [file normalize [file join $cwd ..]]

package require chanlog
package require tcltest
namespace import ::tcltest::*

proc setup {} {
  cleanup
  ::chanlog::init "log.test.db"
  ::chanlog::db eval {
    INSERT INTO log (date, flag, nick, userhost, handle, message) VALUES
      ('2018-10-22 01:02:03', '+', 'makk', '~k1@foo.bar.com', '*', 'first message'),
      ('2019-01-13 01:02:03', '', 'Rect', '~k1@foo.bar.com', '*', 'second message'),
      ('2019-02-22 01:02:03', '@', 'mbp', '~k1@foo.bar.com', '*', 'how is this happening'),
      ('2019-03-22 01:02:03', '', 'makk', '~k1@foo.bar.com', '*', 'unpossible'),
      ('2019-04-22 01:02:03', '', 'john', '~k1@foo.bar.com', '*', 'the only way to ufc'),
      ('2019-05-22 01:02:03', '', 'jack', '~k1@foo.bar.com', '*', 'conor sucks'),
      ('2019-06-22 01:02:03', '', 'jack', '~k1@foo.bar.com', '*', 'what did you say?'),
      ('2019-07-22 01:02:03', '+', 'makk', '~k1@foo.bar.com', '*', 'not this way'),
      ('2019-08-22 01:02:03', '+', 'makk', '~k1@foo.bar.com', '*', 'cool not'),
      ('2019-09-22 01:02:03', '@', 'mbp', '~k1@foo.bar.com', '*', 'dun be dum'),
      ('2019-10-22 01:02:03', '', 'ganj', '~k1@foo.bar.com', '*', 'if you say so'),
      ('2019-10-23 01:02:03', '', 'paul', '~k1@foo.bar.com', '*', 'that is cool'),
      ('2019-10-24 01:02:03', '+', 'makk', '~k1@foo.bar.com', '*', 'penultimate message'),
      ('2019-10-25 01:02:03', '+', 'makk', '~k1@foo.bar.com', '*', 'last message')      
  }
}

proc cleanup {} {
  catch {::chanlog::db close}
  catch {exec rm -f log.test.db}
}

proc dbputs {} {
  foreach {id date flag nick message} [::chanlog::query [join $argv ""]] {
    set dt [clock format [clock scan $date] -format "%m/%d/%y %H:%M:%S"]
    puts [format {=%-4s [%s] <%s%s> %s} $id $dt $flag $nick $message]
  }
}

proc pluck {keys list} {
  set ret {}
  foreach {key value} $list {
    if {[lsearch $keys $key] >= 0} {
      lappend ret $value
    }
  }
  return $ret
}

test chanlog::init "should create empty database" -setup setup -body {
  file exists "log.test.db"
} -result 1

test chanlog::logChannelMessage "should log channel messages" -body {
  ::chanlog::logChannelMessage "makk" "~makk@foo.bar.com" "*" "#mma-tv" "unbelievably awesome"
  ::chanlog::db eval {
    SELECT nick, userhost, handle, message FROM log ORDER BY id DESC LIMIT 1
  } {
    return [expr {
      $nick eq "makk" && $userhost eq "~makk@foo.bar.com" &&
      $handle eq "*" && $message eq "unbelievably awesome"
    }]
  }
  0
} -result 1 -cleanup setup

test chanlog::query "should return empty list when there are no results" -body {
  ::chanlog::query ".log bogus_nonexistent_word"
} -result {}

test chanlog::query "should support query limits" -body {
  llength [pluck id [::chanlog::query ".log4"]]
} -result 4

test chanlog::query "should support nick filtering" -body {
  pluck nick [::chanlog::query ".log,mbp"]
} -result {mbp mbp}

test chanlog::query "should allow searching in chronological order" -body {
  pluck id [::chanlog::query ".log2,+"]
} -result {1 2}

test chanlog::query "should allow searching in reverse chronological order" -body {
  pluck message [::chanlog::query ".log1,-"]
} -result {{last message}}

test chanlog::query "should query in reverse chronological order by default" -body {
  pluck message [::chanlog::query ".log2"]
} -result {{penultimate message} {last message}}

test chanlog::query "should support id matching" -body {
  pluck id [::chanlog::query ".log =4"]
} -result 4

test chanlog::query "should support context lines" -body {
  pluck id [::chanlog::query ".log,-1+3 unpossible"]
} -result {3 4 5 6 7}

cleanup
cleanupTests
