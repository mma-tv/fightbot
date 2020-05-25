#!/usr/bin/env tclsh

variable cwd [file dirname [info script]]
source [file join $cwd eggdrop-stubs.tcl]
::tcl::tm::path add [file normalize [file join $cwd ..]]

package require tcltest
package require chanlog

namespace eval ::chanlog::test {
namespace eval ::chanlog::test::v {
  variable database "chanlog.test.db"
}

namespace import ::tcltest::*

configure -skip {x*}

proc createTable {{cols {}} {values {{}}} {repeat 1}} {
  set extraCols {}
  set extraVals {}

  foreach col {date nick message} {
    if {[lsearch $cols $col] == -1} {
      lappend extraCols $col
      switch $col {
        date    { lappend extraVals "2000-01-01 00:00:00" }
        nick    { lappend extraVals "auto_nick" }
        message { lappend extraVals "default message" }
      }
    }
  }
  lappend cols {*}$extraCols

  set rows [lmap vals [lrepeat $repeat {*}$values] {
    lappend vals {*}$extraVals
    set row [lmap col $cols val $vals {expr {$col eq "ignored" ? $val : "'$val'"}}]
    set row "([join $row ,])"
  }]
  ::chanlog::db eval "DELETE FROM log"
  ::chanlog::db eval "INSERT INTO log ([join $cols ,]) VALUES [join $rows ,]"
}

proc setup {} {
  cleanup
  ::chanlog::init $v::database
}

proc cleanup {} {
  catch {::chanlog::db close}
  catch {exec rm -f $v::database}
}

proc pluck {keys list {cols {id date flag nick message}}} {
  return [join [lmap $cols $list {lmap key $keys {set $key}}]]
}

proc globNoCase {expected actual} {
  return [string match -nocase $expected $actual]
}
customMatch globNoCase [namespace current]::globNoCase

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

test init-database "should create empty database" -setup setup -body {
  expr {[file exists $v::database] && ![::chanlog::db onecolumn {SELECT COUNT(*) FROM log}]}
} -result 1

test log-messages "should log channel messages" -body {
  ::chanlog::logChannelMessage makk k1@foo.bar.com * #mma-tv "unbelievably awesome"
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

test no-results "should return empty list when there are no results" -body {
  createTable
  ::chanlog::query ".log bogus_nonexistent_word"
} -result {}

test query-limits "should support query limits" -body {
  createTable {} {{}} 10
  llength [pluck id [::chanlog::query ".log4"]]
} -result 4

test nick-filter "should support nick filtering" -body {
  createTable {nick} {{foo} {bar} {mbp} {baz} {mbp} {boo}}
  pluck nick [::chanlog::query ".log10,mbp"]
} -result {mbp mbp}

test search-order-1.1 "should allow searching in chronological order" -body {
  createTable {id} {{1} {2} {3} {4}}
  pluck id [::chanlog::query ".log+2"]
} -result {1 2}

test reverse-order-1.1 "should allow searching in reverse chronological order" -body {
  createTable {id} {{1} {2} {3} {4}}
  pluck id [::chanlog::query ".log-2"]
} -result {4 3}

test reverse-order-1.2 "should query in reverse chronological order by default" -body {
  createTable {message} {{first} {second} {third} {fourth}}
  pluck message [::chanlog::query ".log2"]
} -result {fourth third}

test id-match "should support id matching" -body {
  createTable {id message} {{7 seven} {3 three} {9 nine} {4 four} {8 eight}}
  pluck message [::chanlog::query ".log =4"]
} -result {four}

test context-lines "should support context lines" -body {
  createTable {id message} {{1 one} {2 two} {3 unpossible} {4 four} {5 five} {6 six} {7 seven}}
  pluck id [::chanlog::query ".log,-1+3 unpossible"]
} -result {2 3 4 5 6}

test highlight-match "should highlight matching search terms" -body {
  createTable {message} {{"great way"} {awesome} {"the only way"} {"bingo bango"} {the}}
  set output [capture stdout {::chanlog::searchChanLog * * * * ".log the way"}]
  string match "*\002the\002 only \002way\002*" $output
} -result 1

test verbose-mode-1.0 "should support verbose mode" -body {
  createTable {message} {{foo} {"the ufc rocks"} {blah}}
  set fields {id date flag nick userhost handle message}
  llength [pluck $fields [::chanlog::query "..log10 ufc" $fields] $fields]
} -result 7

test verbose-mode-1.1 "should print verbose mode" -body {
  createTable {flag nick userhost message} {
    {+ makk ident@linode.com "bum bum blah z"}
    {{} john * baz}
    {{} Rect k1@foo.bar.com "foo blah bluh"}
  }
  ::chanlog::searchChanLog * * * * "..log10 blah"
} -result 1 -match glob -output {PRIVMSG * :=*<Rect!k1@foo.bar.com>*=*<+makk!ident@linode.com>*}

test help "should return usage help when no args" -body {
  ::chanlog::searchChanLog * * * * ".log"
} -result 1 -match globNoCase -output {*usage*}

test boolean-not "should support boolean NOT queries with -term" -body {
  createTable {message} {
    {"message one"} {"this is a second message"} {foo}
    {"message three"} {"message four"} {bar}
  }
  llength [pluck message [::chanlog::query ".log10 message -second"]]
} -result 3

test boolean-or "should support boolean OR queries" -body {
  createTable {message} {{foo} {"conor fights"} {bar} {baz} {"the ufc"} {fum}}
  llength [pluck message [::chanlog::query ".log10 conor OR ufc"]]
} -result 2

test sanitize-query "should sanitize queries against syntax errors" -body {
  createTable {message} {{ufc} {foo} {"ufc foo"}}
  incr ret [llength [pluck message [::chanlog::query {.log ufc NOT NOT foo +a#a-blah}]]]
} -result 0

test next-page-1.0 "should return next set of results" -body {
  createTable {message} {
    {"the one"} {foo} {"the two"}
    {bar} {baz} {"the three"} {foo}
    {"the four"} {foo} {"the five"} {"the six"}
  }
  ::chanlog::searchChanLog * * * * ".log2 the"
  ::chanlog::searchChanLog * * * * ".logn"
  ::chanlog::searchChanLog * * * * ".logn"
} -result 1 -match glob -output "*six\n*five\n*four\n*three\n*two\n*one\n"

test next-page-1.1 "should indicate when there are no more results" -body {
  createTable {message} {{"the ufc"} {the} {foo}}
  ::chanlog::searchChanLog nick1 * * * ".log10 the"
  ::chanlog::searchChanLog nick1 * * * ".logn"
} -result 1 -match globNoCase -output {*no more*}

test next-page-1.2 "should only show next results for previous query from nick" -body {
  createTable {message} {{"the ufc"} {the} {foo}}
  ::chanlog::searchChanLog nick1 * * * ".log10 the"
  ::chanlog::searchChanLog nick2 * * * ".logn"
} -result 1 -match globNoCase -output {*search for something*}

test ignore-triggers "should ignore messages with .log commands" -body {
  createTable {message ignored} {{".log the" 1} {"the ufc" 0} {".log blah" 1} {".log" 1} {foo 0}}
  ::chanlog::searchChanLog * * * * ".log the"
  ::chanlog::searchChanLog * * * * ".log10"
} -result 1 -match regexp -output {^((?!\.log).)*$}

test column-align "should properly align id column" -body {
  createTable {id} {{1} {32423} {71} {2342343}}
  set output [capture stdout {::chanlog::searchChanLog * * * * ".log10 message"}]
  set lengths [lmap msg [regexp -all -inline -line {^[^[]+} $output] {string length $msg}]
  tcl::mathop::== {*}$lengths
} -result 1

test filter-by-date "should filter by date" -body {
  createTable {date} {{2005-12-01} {2008-01-01} {2019-05-01} {2019-07-03} {2019-08-25} {2020-01-01}}
  llength [pluck id [::chanlog::query ".log10,>=2019-04-20,<=2019-08-24T23:59:59"]]
} -result 2

test boolean-search "should handle multiple boolean operators properly" -body {
  createTable {message} {{"what became of you"}}
  pluck message [::chanlog::query ".log what be* -you"]
} -result {}

cleanup
cleanupTests

}
namespace delete ::chanlog::test
