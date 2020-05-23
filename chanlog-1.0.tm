::tcl::tm::path add [file dirname [info script]]

package require irc
package require log
package require database

namespace eval ::chanlog {
  namespace import ::irc::send ::irc::msend ::database::loadDatabase
}
namespace eval ::chanlog::v {
  variable database "chanlog.db"
  variable dbSetupScript "chanlog.sql"
  variable excludedNicks "^(?:cnr|k1|k-1)$"
  variable maxLimit 100    ;# max search results
  variable defaultLimit 10 ;# default number of search results
  variable defaultSortOrder "-" ;# -(desc), +(asc), =(best match)
}

variable ::chanlog::v::usage {
  {Usage: .[.]log[-+=][limit],[+-contextLines],[nickFilter] [query]}
  {.log5,-3+4,makk|mbp conor sucks}
  {* Find at most 5 log messages that include "conor" and "sucks",}
  {  with 3 lines of context before and 4 lines of context after,}
  {  from nicknames matching the regular expression "makk|mbp".}
  {.log =12345 => Find the log message with id 12345}
  {.log12 (or .log-12) => Fetch last 12 log entries}
  {.log+2 ufc => Find the oldest 2 messages that include "ufc"}
  {.log-2 ufc => Find the newest 2 messages that include "ufc"}
  {.log=2 ufc fight => Find the 2 messages that best match "ufc fight"}
  {.logn => Return next set of results from previous search}
  {..log => Use two leading dots for verbose output (includes userhosts)}
  {End of usage.}
}

variable ::chanlog::v::cteList [dict create cteInput {
  SELECT
    :id AS id,
    :query AS query,
    :includedNicks AS includedNicks,
    :excludedNicks AS excludedNicks,
    :maxLinesBefore AS maxLinesBefore,
    :maxLinesAfter AS maxLinesAfter,
    :offset AS offset,
    :maxResults AS maxResults
} cteNicks {
  SELECT nick
    FROM nicknames
    WHERE nick REGEXP (SELECT includedNicks FROM cteInput)
    AND nick NOT REGEXP (SELECT excludedNicks FROM cteInput)
} cteOldestRecords {
  SELECT m.*
    FROM log m JOIN cteNicks n ON m.nick = n.nick
    WHERE NOT ignored
    ORDER BY id ASC
    LIMIT (SELECT offset FROM cteInput), (SELECT maxResults FROM cteInput)
} cteNewestRecords {
  SELECT m.*
    FROM log m JOIN cteNicks n ON m.nick = n.nick
    WHERE NOT ignored
    ORDER BY id DESC
    LIMIT (SELECT offset FROM cteInput), (SELECT maxResults FROM cteInput)
} cteRecords {
  SELECT m.*
    FROM log m JOIN cteNicks n ON m.nick = n.nick
    WHERE NOT ignored
} cteMatches {
  SELECT id, rank
    FROM log_fts
    WHERE nick IN (SELECT nick FROM cteNicks)
    AND message MATCH (SELECT query FROM cteInput)
} cteOldestMatches {
  SELECT r.*
    FROM cteRecords r JOIN cteMatches m ON r.id = m.id
    ORDER BY r.id ASC
    LIMIT (SELECT offset FROM cteInput), (SELECT maxResults FROM cteInput)
} cteNewestMatches {
  SELECT r.*
    FROM cteRecords r JOIN cteMatches m ON r.id = m.id
    ORDER BY r.id DESC
    LIMIT (SELECT offset FROM cteInput), (SELECT maxResults FROM cteInput)
} cteBestMatches {
  SELECT r.*
    FROM cteRecords r JOIN cteMatches m ON r.id = m.id
    ORDER BY m.rank
    LIMIT (SELECT offset FROM cteInput), (SELECT maxResults FROM cteInput)
} cteMatch {
  SELECT *
    FROM cteRecords
    WHERE id = (SELECT id FROM cteInput)
} cteContextBefore {
  SELECT *
    FROM cteRecords
    WHERE id < (SELECT id FROM cteMatch)
    ORDER BY id DESC LIMIT (SELECT maxLinesBefore FROM cteInput)
} cteContextAfter {
  SELECT *
    FROM cteRecords
    WHERE id > (SELECT id FROM cteMatch)
    ORDER BY id ASC LIMIT (SELECT maxLinesAfter FROM cteInput)
}]

proc ::chanlog::init {{database ""}} {
  set dbFile [expr {$database eq "" ? $v::database : $database}]
  loadDatabase ::chanlog::db $dbFile $v::dbSetupScript
}

proc ::chanlog::WITH {args} {
  set ctes {}
  foreach cte $args {
    lappend ctes "$cte AS ([dict get $v::cteList $cte])"
  }
  return "WITH [join $ctes ,]"
}

proc ::chanlog::sanitizeQuery {text} {
  regsub -all {(\w\**)\s+OR\s+(\+*\w)} $text "\\1 \uE000 \\2" text
  regsub -all {\m(AND|OR|NOT|NEAR)\M} $text "\uE001\\1\uE001" text
  regsub -all {[^-*\w\x5B-\uFFFF]+} $text " " text
  regsub -all {(\w)\*+(?=\s|$)} $text "\\1\uE002" text
  regsub -all {(?:^|\s)-(\w)} $text " \uE003 \\1" text
  regsub -all {[-* ]+} $text " " text
  set text [string map {\uE000 OR \uE001 \" \uE002 * \uE003 NOT} $text]
  regsub {^\s*(?:NOT\s+)+} $text "" text
  return [string trim $text]
}

proc ::chanlog::query {text {fields {id date flag nick message}} {offset 0}} {
  set cmd [lindex [split $text] 0]
  set query [string trim [join [lrange [split $text] 1 end]]]
  set cols [join $fields ", "]

  set maxResults $v::defaultLimit
  set dateFilters {}
  set contextLines ""
  set includedNicks ""
  set excludedNicks $v::excludedNicks
  set WHERE ""

  set args [split $cmd ,]
  regexp {([-+=]?)((?:\d+)?)$} [lindex $args 0] m sortOrder maxResults
  set sortOrder [expr {$sortOrder eq "" ? $v::defaultSortOrder : $sortOrder}]
  set maxResults [expr {min($maxResults eq "" ? $v::defaultLimit : $maxResults, $v::maxLimit)}]

  foreach arg [lrange $args 1 end] {
    switch -regexp -matchvar m -- $arg {
      {^([<>]?=?)(\d[\d\s:-]*)$} { lappend dateFilters [lindex $m 1] [lindex $m 2] }
      {^(?:-\d+(?:\+\d+)?|\+\d+(?:-\d+)?)$} { set contextLines $arg }
      {\w} { set includedNicks $arg }
    }
  }

  if {[llength $dateFilters]} {
    set filters {}
    foreach {op date} $dateFilters {
      if {[string match [regsub -all {\d} $date d]* "dddd-dd-dd dd:dd:dd"]} {
        lappend filters "date [expr {$op eq "" ? "=" : $op}] '$date'"
      }
    }
    if {[llength $filters]} {
      set WHERE "WHERE [join $filters " AND "]"
    }
  }

  if {[regexp {^=(\d+)$} $query m id]} {
    set sql "SELECT $cols FROM log WHERE id = :id"
  } else {
    set query [sanitizeQuery $query]

    if {$query eq ""} {
      set cteRecords [expr {$sortOrder eq "+" ? "cteOldestRecords" : "cteNewestRecords"}]
      set sql "[WITH cteInput cteNicks $cteRecords]\
        SELECT $cols FROM $cteRecords $WHERE ORDER BY id"
    } else {
      switch -- $sortOrder {
        {-} { set cteSortedMatches "cteNewestMatches" }
        {+} { set cteSortedMatches "cteOldestMatches" }
        {=} { set cteSortedMatches "cteBestMatches" }
      }
      set sql "[WITH cteInput cteNicks cteRecords cteMatches $cteSortedMatches]\
        SELECT $cols FROM $cteSortedMatches $WHERE ORDER BY id"
    }
  }

  set result [db eval $sql]
  set totalRows [expr {[llength $result] / [llength $cols]}]

  if {$totalRows == 1 && $contextLines ne ""} {
    set id [lindex $result 0]
    set maxLinesBefore [regexp -inline -- {-\d+} $contextLines]
    set maxLinesAfter [regexp -inline -- {\+\d+} $contextLines]
    set maxLinesBefore [expr {($maxLinesBefore ne "" && $maxLinesBefore < 0) ? abs($maxLinesBefore) : 0}]
    set maxLinesAfter [expr {($maxLinesAfter > 0) ? $maxLinesAfter : 0}]
    set highlightMatches [expr {$maxLinesBefore || $maxLinesAfter}]

    set sql "[WITH cteInput cteNicks cteRecords cteMatch cteContextBefore cteContextAfter]\
      SELECT $cols FROM cteContextBefore $WHERE\
      UNION SELECT $cols FROM cteMatch $WHERE\
      UNION SELECT $cols FROM cteContextAfter $WHERE\
      ORDER BY id\
      LIMIT (SELECT maxResults FROM cteInput)"

    set result [db eval $sql]
  }

  return $result
}

proc ::chanlog::searchChanLog {unick host handle dest text {offset 0}} {
  set ret [::log::logStackable $unick $host $handle $dest $text]
  set cmd [lindex [split $text] 0]
  set query [string trim [join [lrange [split $text] 1 end]]]
  set args [list $unick $host $handle $dest $text]

  if {[string match .logn* $cmd]} {
    if {[info exists v::nextResults($unick!$host)]} {
      searchChanLog {*}$v::nextResults($unick!$host)
    } else {
      send $unick $dest "You have to search for something first."
    }
    return $ret
  }

  if {[regexp -nocase {^\.+log[a-z]*(?![-+=]?\d+)$} $cmd] && $query eq ""} {
    msend $unick $dest $v::usage
    return $ret
  }

  set totalResults 0
  set fmt {=%d [%s] <%s%s> %s}
  set fields {id date flag nick message}
  if {[string match ..* $cmd]} { ;# verbose output
    set fmt {=%d [%s] <%s%s!%s> %s}
    set fields {id date flag nick userhost message}
  }

  set results [query $text $fields $offset]
  set maxId 0
  foreach $fields $results {
    set maxId [expr {max($id, $maxId)}]
  }
  regsub {^=%} $fmt "\&-[string length $maxId]" fmt

  foreach $fields $results {
    set text [format $fmt {*}[lmap field $fields {set $field}]]
    send $unick $dest $text
    incr totalResults
  }
  if {$totalResults > 0} {
    set v::nextResults($unick!$host) [lappend args [expr {$offset + $totalResults}]]
  } else {
    array unset v::nextResults($unick!$host)
    send $unick $dest "No more search results."
  }

  return $ret
}
::irc::mbind {msgm pubm} - {"% .log*"} ::chanlog::searchChanLog
::irc::mbind {msgm pubm} - {"% ..log*"} ::chanlog::searchChanLog

proc ::chanlog::logChannelMessage {nick userhost handle channel message} {
  set date [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
  set flag [expr {[isop $nick $channel] ? "@" : ([isvoice $nick $channel] ? "+" : "")}]
  set ignored [regexp -nocase {^\.+log} $message]
  if {[catch {db eval {
    INSERT INTO log (date, flag, nick, userhost, handle, message, ignored)
      VALUES (:date, :flag, :nick, :userhost, :handle, :message, :ignored)
  }}]} {
    putlog "::chanlog::logChannelMessage => Failed to log channel message: $::errorInfo"
  }
}
::irc::mbind pubm - * ::chanlog::logChannelMessage
return
