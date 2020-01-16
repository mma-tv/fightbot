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
  {.log =12345 => Find the log message with id 12345}
  {..log => Use two leading dots for verbose output (includes userhosts)}
  {.log12 (or .log-12) => Fetch last 12 log entries}
  {.log+2 ufc => Find the oldest 2 messages that include "ufc"}
  {.log-2 ufc => Find the newest 2 messages that include "ufc"}
  {.log=2 ufc fight => Find the 2 messages that best match "ufc fight"}
  {.log5,-3+4,makk|mbp conor sucks}
  {* Find at most 5 log messages that include "conor" and "sucks",}
  {  with 3 lines of context before and 4 lines of context after,}
  {  from nicknames matching the regular expression "makk|mbp".}
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
    ORDER BY id ASC
    LIMIT (SELECT offset FROM cteInput), (SELECT maxResults FROM cteInput)
} cteNewestRecords {
  SELECT m.*
    FROM log m JOIN cteNicks n ON m.nick = n.nick
    ORDER BY id DESC
    LIMIT (SELECT offset FROM cteInput), (SELECT maxResults FROM cteInput)
} cteRecords {
  SELECT m.*
    FROM log m JOIN cteNicks n ON m.nick = n.nick
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

proc ::chanlog::query {text {fields {id date flag nick message}}} {
  set cmd [lindex [split $text] 0]
  set query [string trim [join [lrange [split $text] 1 end]]]
  set cols [join $fields ", "]

  set offset 0
  set maxResults $v::defaultLimit
  set contextLines ""
  set includedNicks ""
  set excludedNicks $v::excludedNicks

  set args [split $cmd ,]
  regexp {([-+=]?)((?:\d+)?)$} [lindex $args 0] m sortOrder maxResults
  set sortOrder [expr {$sortOrder eq "" ? $v::defaultSortOrder : $sortOrder}]
  set maxResults [expr {min($maxResults eq "" ? $v::defaultLimit : $maxResults, $v::maxLimit)}]

  foreach arg [lrange $args 1 end] {
    switch -regexp -- $arg {
      {^(?:-\d+(?:\+\d+)?|\+\d+(?:-\d+)?)$} { set contextLines $arg }
      {\w} { set includedNicks $arg }
    }
  }

  if {[regexp {^=(\d+)$} $query m id]} {
    set sql "SELECT $cols FROM log WHERE id = :id"
  } elseif {$query eq ""} {
    set cteRecords [expr {$sortOrder eq "+" ? "cteOldestRecords" : "cteNewestRecords"}]
    set sql "[WITH cteInput cteNicks $cteRecords] SELECT $cols FROM $cteRecords ORDER BY id"
  } else {
    switch -- $sortOrder {
      {-} { set cteSortedMatches "cteNewestMatches" }
      {+} { set cteSortedMatches "cteOldestMatches" }
      {=} { set cteSortedMatches "cteBestMatches" }
    }
    set sql "[WITH cteInput cteNicks cteRecords cteMatches $cteSortedMatches]\
      SELECT $cols FROM $cteSortedMatches ORDER BY id"
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
      SELECT $cols FROM cteContextBefore\
      UNION SELECT $cols FROM cteMatch\
      UNION SELECT $cols FROM cteContextAfter\
      ORDER BY id\
      LIMIT (SELECT offset FROM cteInput), (SELECT maxResults FROM cteInput)"

    set result [db eval $sql]
  }

  return $result
}

proc ::chanlog::logChannelMessage {nick userhost handle channel message} {
  set date [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
  set flag [expr {[isop $nick $channel] ? "@" : ([isvoice $nick $channel] ? "+" : "")}]
  if {[catch {db eval {
    INSERT INTO log (date, flag, nick, userhost, handle, message)
      VALUES (:date, :flag, :nick, :userhost, :handle, :message)
  }}]} {
    putlog "::chanlog::logChannelMessage => Failed to log channel message: $::errorInfo"
  }
}
::irc::mbind pubm - * ::chanlog::logChannelMessage

proc ::chanlog::searchChanLog {unick host handle dest text} {
  set ret [::log::logStackable $unick $host $handle $dest $text]
  set cmd [lindex [split $text] 0]
  set query [string trim [join [lrange [split $text] 1 end]]]

  if {[regexp -nocase {^\.+log[a-z]*(?![-+=]?\d+)$} $cmd] && $query eq ""} {
    msend $unick $dest $v::usage
  } elseif {[string match ..* $cmd]} { ;# verbose output
    set fields {id date flag nick userhost handle message}
    foreach $fields [query $text $fields] {
      set text [format {=%d [%s] (%s) <%s%s!%s> %s} $id $date $handle $flag $nick $userhost $message]
      send $unick $dest $text
    }
  } else {
    foreach {id date flag nick message} [query $text] {
      set text [format {=%d [%s] <%s%s> %s} $id $date $flag $nick $message]
      send $unick $dest $text
    }
  }

  return $ret
}
::irc::mbind {msgm pubm} n {"% .log*"} ::chanlog::searchChanLog
::irc::mbind {msgm pubm} n {"% ..log*"} ::chanlog::searchChanLog
return
