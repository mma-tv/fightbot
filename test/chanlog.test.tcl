#!/usr/bin/env tclsh

variable cwd [file dirname [info script]]
source [file join $cwd eggdrop-stubs.tcl]
::tcl::tm::path add [file normalize [file join $cwd ..]]

package require tcltest
package require tcltestx
package require chanlog

namespace eval ::chanlog::test {
namespace eval ::chanlog::test::v {
  variable database "chanlog.test.db"
}

namespace import ::tcltest::*
namespace import ::tcltestx::*

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
  ::chanlog::db eval "DELETE FROM sqlite_sequence WHERE name = 'log'";
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

proc pluck {keys list {cols {id date flag nick message context}}} {
  return [join [lmap $cols $list {lmap key $keys {set $key}}]]
}

########################################

setup

test init-database "should create empty database" -setup setup -body {
  expr {[file exists $v::database] && ![::chanlog::db onecolumn {SELECT COUNT(*) FROM log}]}
} -result 1

test log-messages "should log channel messages" -setup setup -body {
  set args {makk k1@foo.bar.com * #mma-tv "super cool"}
  ::chanlog::logChannelMessage {*}$args
  set vals [::chanlog::db eval {SELECT nick, userhost, handle, '#mma-tv', message FROM log}]
  expr {[list {*}$vals] == [list {*}$args]}
} -result 1

test query "should find query terms" -body {
  createTable {id message} {{1 test} {2 "foo bar"} {3 baz}}
  pluck id [::chanlog::query ".log-1 bar"]
} -result 2

test id-match "should support id matching" -body {
  createTable {id message} {{7 seven} {3 three} {9 nine} {4 four} {8 eight}}
  pluck message [::chanlog::query ".log =4"]
} -result {four}

test context-lines "should support context lines" -body {
  createTable {id message} {{1 one} {2 two} {3 whatever} {4 four} {5 five} {6 six} {7 seven}}
  pluck id [::chanlog::query ".log-10,-1+3 whatever"]
} -result {2 3 4 5 6}

test highlight-match "should highlight matching search terms" -body {
  createTable {message} {{"great way"} {awesome} {"the only way"} {"bingo bango"}}
  set output [capture stdout {::chanlog::searchChanLog * * * * ".log-10 the OR way"}]
  regexp {^[^\n]+:[^\n]*\002the\002 only \002way\002\r?\n[^\n]+:[^\n]*great \002way\002\r?\n$} $output
} -result 1

test dcc-query "should support queries through DCC chat" -body {
  createTable {id message} {{3 foo} {4 bar} {5 baz}}
  set output [capture stdout [list ::chanlog::dccSearchChanLog makk 5 ".log-1 bar"]]
  regexp {^[^\n]+ \002bar\002\r?\n$} $output
} -result 1

test no-results "should return empty list when there are no results" -body {
  createTable
  ::chanlog::query ".log nonexistent_word_xywoacb"
} -result {}

test query-limits "should support query limits" -body {
  createTable {message} {{test}} 10
  llength [pluck id [::chanlog::query ".log-4 test"]]
} -result 4

test query-max-limit-1.0 "should respect query max limit" -body {
  createTable {message} {{test}} 200
  llength [pluck id [::chanlog::query ".log-200 test"]]
} -result 100

test query-max-limit-1.1 "should return no results if match plus context lines exceed max limit" -body {
  createTable {message} {{test}} 500
  llength [pluck id [::chanlog::query ".log,-300+300 =250"]]
} -result 0

test query-max-limit-1.2 "should respect query max limit with context" -body {
  createTable {message} {{test}} 500
  llength [pluck id [::chanlog::query ".log,-49+50 =250"]]
} -result 100

test query-max-limit-1.3 "should respect query max limit with context" -body {
  createTable {message} {{test}} 500
  llength [pluck id [::chanlog::query ".log,-99 =250"]]
} -result 100

test query-limit-with-context "should increase query limit to accommodate context lines" -body {
  createTable {message} {{test}} 200
  llength [pluck id [::chanlog::query ".log-5,-10+10 =100"]]
} -result 21

test nick-filter "should support nick filtering" -body {
  createTable {nick} {{foo} {bar} {mbp} {baz} {mbp} {boo}}
  pluck nick [::chanlog::query ".log-10,mbp"]
} -result {mbp mbp}

test sort-ascending "should allow searching in chronological order" -body {
  createTable {id} {{6} {7} {8} {9}}
  pluck id [::chanlog::query ".log+2"]
} -result {6 7}

test sort-descending "should allow searching in reverse chronological order" -body {
  createTable {id} {{2} {3} {4} {5}}
  pluck id [::chanlog::query ".log-2"]
} -result {5 4}

test sort-rank "should allow searching by best match" -body {
  createTable {id message} {
    {1 "foo bar baz zum"} {2 "bar foo baz zum foo baz"}
    {3 "foo zum baz"} {4 "foo baz"}
  }
  pluck id [::chanlog::query ".log=2 foo baz"]
} -result {4 2} ;# exact match followed by highest frequency

test sort-default "should respect default sort order" -body {
  createTable {message} {{first} {second} {third} {fourth}}
  set ret1 [pluck message [::chanlog::query ".log2"]]
  set ret2 [pluck message [::chanlog::query ".log${::chanlog::v::defaultSortOrder}2"]]
  expr {$ret1 == $ret2}
} -result 1

test verbose-mode-1.0 "should support verbose mode" -body {
  createTable {message} {{foo} {"the ufc rocks"} {blah}}
  set fields {id date flag nick userhost handle message}
  llength [pluck $fields [::chanlog::query "..log-10 ufc" $fields] $fields]
} -result 7

test verbose-mode-1.1 "should print verbose mode" -body {
  createTable {flag nick userhost message} {
    {+ makk ident@linode.com "bum bum blah z"}
    {{} john * baz}
    {{} Rect k1@foo.bar.com "foo blah bluh"}
  }
  ::chanlog::searchChanLog * * * * "..log-10 blah"
} -result 1 -match glob -output {PRIVMSG * :=*<Rect!k1@foo.bar.com>*=*<+makk!ident@linode.com>*}

test help-1.0 "should return usage help when no args" -body {
  ::chanlog::searchChanLog * * * * ".log   "
} -result 1 -match globNoCase -output {*usage*}

test help-1.1 "should return usage help for invalid args" -body {
  ::chanlog::searchChanLog * * * * ".logn3"
} -result 1 -match globNoCase -output {*usage*}

test boolean-not "should support boolean NOT queries with -term" -body {
  createTable {id message} {
    {1 "message one"} {2 "this is a second message"} {3 foo}
    {4 "message three"} {5 "message four"} {6 bar}
  }
  pluck id [::chanlog::query ".log-10 message -second"]
} -result {5 4 1}

test boolean-or "should support boolean OR queries" -body {
  createTable {message} {{foo} {"conor fights"} {bar} {baz} {"the ufc"} {fum}}
  llength [pluck message [::chanlog::query ".log-10 conor OR ufc"]]
} -result 2

test sanitize-query "should sanitize queries against syntax errors" -body {
  createTable {message} {{ufc} {foo} {"ufc foo"}}
  incr ret [llength [pluck message [::chanlog::query {.log-1 ufc NOT NOT foo +a#a-blah}]]]
} -result 0

test next-page-1.0 "should return next set of results" -body {
  createTable {message} {
    {"the one"} {foo} {"the two"}
    {bar} {baz} {"the three"} {foo}
    {"the four"} {foo} {"the five"} {"the six"}
  }
  ::chanlog::searchChanLog * * * * ".log-2 the"
  ::chanlog::searchChanLog * * * * ".logn"
  ::chanlog::searchChanLog * * * * ".logn"
} -result 1 -match glob -output "*six\n*five\n*four\n*three\n*two\n*one\n"

test next-page-1.1 "should indicate when there are no more results" -body {
  createTable {message} {{"the ufc"} {the} {foo}}
  ::chanlog::searchChanLog nick1 * * * ".log-10 the"
  ::chanlog::searchChanLog nick1 * * * ".logn"
} -result 1 -match globNoCase -output {*no more*}

test next-page-1.2 "should only show next results for previous query from nick" -body {
  createTable {message} {{"the ufc"} {the} {foo}}
  ::chanlog::searchChanLog nick1 * * * ".log-10 the"
  ::chanlog::searchChanLog nick2 * * * ".logn"
} -result 1 -match globNoCase -output {*search for something*}

test next-page-1.3 "should paginate with context lines" -body {
  createTable {id message} {
    {1 one} {2 "the two"} {3 three} {4 four}
    {5 five} {6 "the six"} {7 seven} {8 eight} {9 nine}
  }
  set res1 [capture stdout {::chanlog::searchChanLog * * * * ".log-1,-1+1 the"}]
  set res2 [capture stdout {::chanlog::searchChanLog * * * * ".logn"}]
  set ret1 [regexp {^[^\n]+five\r?\n[^\n]+six.?\r?\n[^\n]+seven\r?\n$} $res1]
  set ret2 [regexp {^[^\n]+one\r?\n[^\n]+two.?\r?\n[^\n]+three\r?\n$} $res2]
  expr {$ret1 && $ret2}
} -result 1

test next-page-1.4 "should also allow pagination with ..logn" -body {
  createTable {message} {{"the one"} {foo} {"the two"}}
  ::chanlog::searchChanLog * * * * ".log-1 the"
  ::chanlog::searchChanLog * * * * "..logn"
} -result 1 -match glob -output "*two\n*one\n"

test ignore-triggers "should ignore messages with .log commands" -body {
  createTable {message ignored} {{".log3 the" 1} {"the ufc" 0} {".log blah" 1} {".log" 1} {foo 0}}
  ::chanlog::searchChanLog * * * * ".log the"
  ::chanlog::searchChanLog * * * * ".log-10"
} -result 1 -match regexp -output {^((?!\.log).)*$}

test column-align "should properly align id column" -body {
  createTable {id} {{1} {32423} {71} {2342343}}
  set output [capture stdout {::chanlog::searchChanLog * * * * ".log-10 message"}]
  set lengths [lmap msg [regexp -all -inline -line {^[^[]+} $output] {string length $msg}]
  tcl::mathop::== {*}$lengths
} -result 1

test filter-by-date "should filter by date" -body {
  createTable {date} {{2005-12-01} {2008-01-01} {2019-05-01} {2019-07-03} {2019-08-25} {2020-01-01}}
  pluck date [::chanlog::query ".log+10,>=2019-04-20,<=2019-08-24T23:59"]
} -result {2019-05-01 2019-07-03}

test limit-channel-results-1.0 "should limit results posted in channels" -body {
  createTable {message} {{test}} 20
  set output [capture stdout {::chanlog::searchChanLog * * * #mma-tv ".log-20 test"}]
  regexp {^(?:NOTICE[^\n]+\n)+$} $output
} -result 1

test limit-channel-results-1.1 "should post results to channel if less than public limit" -body {
  set maxPublic $::chanlog::v::maxPublic
  createTable {message} {{test}} [expr {$maxPublic * 2}]
  set output [capture stdout [list ::chanlog::searchChanLog * * * #mma-tv ".log$maxPublic test"]]
  regexp {^(?:PRIVMSG[^\n]+\n)+$} $output
} -result 1

test boolean-search "should handle multiple boolean operators properly" -body {
  createTable {message} {{"what became of you"}}
  pluck message [::chanlog::query ".log-1 what be* -you"]
} -result {}

cleanup
cleanupTests

}
namespace delete ::chanlog::test
