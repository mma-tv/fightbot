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
    INSERT INTO log (date, flag, nick, userhost, handle, message, ignored) VALUES
      ('2018-10-22 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'first message', 0),
      ('2019-01-13 01:02:03', '', 'Rect', 'k1@foo.bar.com', '*', 'second message', 0),
      ('2019-02-22 01:02:03', '@', 'mbp', 'k1@foo.bar.com', '*', 'how is this happening', 0),
      ('2019-03-22 01:02:03', '', 'makk', 'k1@foo.bar.com', '*', 'unpossible', 0),
      ('2019-04-22 01:02:03', '', 'john', 'k1@foo.bar.com', '*', 'the only way to ufc', 0),
      ('2019-05-22 01:02:03', '', 'jack', 'k1@foo.bar.com', '*', 'conor sucks', 0),
      ('2019-06-22 01:02:03', '', 'jack', 'k1@foo.bar.com', '*', 'what did you say?', 0),
      ('2019-07-22 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'not this way', 0),
      ('2019-07-23 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', '.log the way', 1),
      ('2019-08-22 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'the one', 0),
      ('2019-08-23 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'the two', 0),
      ('2019-08-24 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'the three', 0),
      ('2019-08-25 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'the four', 0),
      ('2019-08-26 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'the five', 0),
      ('2019-08-27 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'the six', 0),
      ('2019-08-28 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'the seven', 0),
      ('2019-08-29 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'cool not', 0),
      ('2019-09-22 01:02:03', '@', 'mbp', 'k1@foo.bar.com', '*', 'dun be dum', 0),
      ('2019-10-22 01:02:03', '', 'ganj', 'k1@foo.bar.com', '*', 'if you say so', 0),
      ('2019-10-23 01:02:03', '', 'paul', 'k1@foo.bar.com', '*', 'that is cool', 0),
      ('2019-10-24 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'penultimate message', 0),
      ('2019-10-25 01:02:03', '+', 'makk', 'k1@foo.bar.com', '*', 'last message', 0)
  }
}

proc cleanup {} {
  catch {::chanlog::db close}
  catch {exec rm -f log.test.db}
}

proc pluck {keys list {cols {id date flag nick message}}} {
  set ret {}
  foreach $cols $list {
    foreach key $keys {
      lappend ret [set $key]
    }
  }
  return $ret
}

proc globNoCase {expected actual} {
  return [string match -nocase $expected $actual]
}
customMatch globNoCase globNoCase

test chanlog::init "should create empty database" -setup setup -body {
  file exists "log.test.db"
} -result 1

if {0} {
test chanlog::logChannelMessage "should log channel messages" -body {
  ::chanlog::logChannelMessage "makk" "k1@foo.bar.com" "*" "#mma-tv" "unbelievably awesome"
  ::chanlog::db eval {
    SELECT nick, userhost, handle, message FROM log ORDER BY id DESC LIMIT 1
  } {
    return [expr {
      $nick eq "makk" && $userhost eq "k1@foo.bar.com" &&
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
  pluck id [::chanlog::query ".log+2"]
} -result {1 2}

test chanlog::query "should allow searching in reverse chronological order" -body {
  pluck message [::chanlog::query ".log-1"]
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

test chanlog::query "should support verbose mode" -body {
  set fields {id date flag nick userhost handle message}
  llength [pluck $fields [::chanlog::query "..log ufc" $fields] $fields]
} -result 7

test chanlog::searchChanLog "should print verbose mode" -body {
  ::chanlog::searchChanLog * * * * "..log message"
} -result 1 -match glob -output {PRIVMSG * :=1 *<+makk!k1@foo.bar.com>*=2 *<Rect!k1@foo.bar.com>*}

test chanlog::searchChanLog "should return usage help when no args" -body {
  ::chanlog::searchChanLog * * * * ".log"
} -result 1 -match globNoCase -output {*usage*}

test chanlog::query "should support boolean NOT queries with -term" -body {
  llength [pluck message [::chanlog::query ".log message -second"]]
} -result 3

test chanlog::query "should support boolean OR queries" -body {
  llength [pluck message [::chanlog::query ".log conor OR ufc"]]
} -result 2

test chanlog::query "should sanitize queries against syntax errors" -body {
  set ret 0
  incr ret [llength [pluck message [::chanlog::query {.log ufc NOT NOT foo +a#a-blah}]]]
} -result 0

test chanlog::searchChanLog "should return next set of results" -body {
  ::chanlog::searchChanLog * * * * ".log2 the"
  ::chanlog::searchChanLog * * * * ".logn"
  ::chanlog::searchChanLog * * * * ".logn"
} -result 1 -match glob -output "*\n*\n*four*\n*five*\n*two*\n*three\n"

test chanlog::searchChanLog "should indicate when there are no more results" -body {
  ::chanlog::searchChanLog * * * * ".log20 the"
  ::chanlog::searchChanLog * * * * ".logn"
} -result 1 -match globNoCase -output {*no more*}

test chanlog::searchChanLog "should only show next results for previous query from nick" -body {
  ::chanlog::searchChanLog foo * * * ".log20 the"
  ::chanlog::searchChanLog bar * * * ".logn"
} -result 1 -match globNoCase -output {*search for something*}

test chanlog::searchChanLog "should ignore messages with .log commands" -body {
  ::chanlog::searchChanLog * * * * ".log the"
  ::chanlog::searchChanLog * * * * ".log100"
} -result 1 -match regexp -output {^((?!\.log).)*$}

test chanlog::searchChanLog "should properly align id column" -body {
  ::chanlog::searchChanLog * * * * ".log message"
} -result 1 -match regexp -output {.*:=\d  \[.*:=\d\d \[}
}

test chanlog::query "should filter by date" -body {
  llength [pluck id [::chanlog::query ".log,>=2019-04-22,<=2019-08-24 the"]]
} -result 3

test chanlog::query "should filter by date" -body {
  llength [pluck id [::chanlog::query ".log,=2019-04-22 the"]]
} -result 1

cleanup
cleanupTests
