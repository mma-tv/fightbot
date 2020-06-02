::tcl::tm::path add [file dirname [info script]]

package require irc
package require log
package require database

namespace eval ::chanlog {
  namespace import ::irc::send ::irc::msend ::irc::mpost ::irc::msg
}
namespace eval ::chanlog::v {
  variable database "chanlog.db"
  variable dbSetupScript "chanlog.sql"
  variable maxPublic 3     ;# max results to post to channel
  variable maxResults 100    ;# max search results
  variable defaultLimit 1  ;# default number of search results
  variable defaultSortOrder "-" ;# -(desc), +(asc), =(best match)
}

variable ::chanlog::v::usage {
  {Usage: .[.]log[-+=][limit],[+-contextLines],[>=dateFilter],[nickFilter] [query]}
  {.log,-2+3,kano|bruk ufc jon}
  {* Find most recent message that includes "ufc" and "jon",}
  {  with 2 lines of context before and 3 lines of context after,}
  {  from nicknames matching the regular expression /kano|bruk/}
  {.log cowboy OR cerr* -music => Boolean search with wildcards}
  {.log @12345 => Find log message with id 12345}
  {.log10 (or .log-10) => Find last 10 log entries}
  {.log+2 ufc => Find oldest 2 messages that include "ufc"}
  {.log-2 ufc => Find newest 2 messages that include "ufc"}
  {.log=2 ufc fight => Find 2 messages that best match "ufc fight"}
  {.log,>=2020-03-02,<2020-04-01T15:30 dana => Filter results by date/time}
  {..log => Print results with verbose output (includes userhosts)}
  {.logn => Print next set of results from previous search}
  {End of usage.}
}

variable ::chanlog::v::cteList [dict create cteInput {
  SELECT
    :query AS query,
    :matchId AS matchId,
    :includedNicks AS includedNicks,
    :maxLinesBefore AS maxLinesBefore,
    :maxLinesAfter AS maxLinesAfter
} cteRecords {
  SELECT *
    FROM log
    WHERE nick REGEXP (SELECT includedNicks FROM cteInput)
      AND NOT ignored
} cteOldestRecords {
  SELECT *
    FROM cteRecords
    ORDER BY id ASC
} cteNewestRecords {
  SELECT *
    FROM cteRecords
    ORDER BY id DESC
} cteMatches {
  SELECT id, rank, highlight(log_fts, 2, CHAR(2), CHAR(2)) AS marked_message
    FROM log_fts
    WHERE message MATCH (SELECT query FROM cteInput)
} cteOldestMatches {
  SELECT *
    FROM cteRecords r JOIN cteMatches m ON r.id = m.id
    ORDER BY r.id ASC
} cteNewestMatches {
  SELECT *
    FROM cteRecords r JOIN cteMatches m ON r.id = m.id
    ORDER BY r.id DESC
} cteBestMatches {
  SELECT *
    FROM cteRecords r JOIN cteMatches m ON r.id = m.id
    ORDER BY m.rank
} cteMatch {
  SELECT *
    FROM cteRecords
    WHERE id = (SELECT matchId FROM cteInput)
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
  ::database::loadDatabase ::chanlog::db $dbFile $v::dbSetupScript
}

proc ::chanlog::WITH {args} {
  set ctes [lmap cte $args {set x "$cte AS ([dict get $v::cteList $cte])"}]
  return "WITH [join $ctes ,]"
}

proc ::chanlog::cols {fields args} {
  return [join [lmap field $fields {
    foreach {old new} [concat $args context "''"] {
      if {$old eq $field} {
        set field "$new AS $old"
        break
      }
    }
    set field
  }] ,]
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

proc ::chanlog::query {text {fields {id date flag nick message context}} {offset 0}} {
  set cmd [lindex [split $text] 0]
  set query [string trim [join [lrange [split $text] 1 end]]]

  set maxMatches $v::defaultLimit
  set dateFilters {}
  set contextLines ""
  set includedNicks ""
  set WHERE ""

  set args [split $cmd ,]
  regexp {([-+=]?)((?:\d+)?)$} [lindex $args 0] m sortOrder maxMatches
  set sortOrder [expr {$sortOrder eq "" ? $v::defaultSortOrder : $sortOrder}]
  set maxMatches [expr {min($maxMatches eq "" ? $v::defaultLimit : $maxMatches, $v::maxResults)}]

  foreach arg [lrange $args 1 end] {
    switch -regexp -matchvar m -- $arg {
      {^([<>]?=?)(\d[-\dT:]*)$} { lappend dateFilters [lindex $m 1] [lindex $m 2] }
      {^(?:-\d+(?:\+\d+)?|\+\d+(?:-\d+)?)$} { set contextLines $arg }
      {\w} { set includedNicks $arg }
    }
  }

  if {[llength $dateFilters]} {
    set filters {}
    foreach {op date} $dateFilters {
      if {[string match [regsub -all {\d} $date d]* "dddd-dd-ddTdd:dd:ddZ"]} {
        lappend filters "date [expr {$op eq "" ? "=" : $op}] DATETIME('$date')"
      }
    }
    if {[llength $filters]} {
      set WHERE "WHERE ([join $filters " AND "])"
    }
  }

  if {[regexp {^@(\d+)$} $query m id]} {
    set cols [cols $fields context "'match'"]
    set sql "SELECT $cols FROM log WHERE id = :id LIMIT :offset, :maxMatches"
  } else {
    set query [sanitizeQuery $query]

    if {$query eq ""} {
      set cteRecords [expr {$sortOrder eq "+" ? "cteOldestRecords" : "cteNewestRecords"}]
      set sql "[WITH cteInput cteRecords $cteRecords]\
        SELECT [cols $fields] FROM $cteRecords $WHERE LIMIT :offset, :maxMatches"
    } else {
      switch -- $sortOrder {
        {-} { set cteSortedMatches "cteNewestMatches" }
        {+} { set cteSortedMatches "cteOldestMatches" }
        {=} { set cteSortedMatches "cteBestMatches" }
      }
      set cols [cols $fields message marked_message context "'match'"]
      set sql "[WITH cteInput cteRecords cteMatches $cteSortedMatches]\
        SELECT $cols FROM $cteSortedMatches $WHERE LIMIT :offset, :maxMatches"
    }
  }

  set maxLinesBefore [regexp -inline -- {-\d+} $contextLines]
  set maxLinesAfter [regexp -inline -- {\+\d+} $contextLines]
  set maxLinesBefore [expr {($maxLinesBefore ne "" && $maxLinesBefore < 0) ? abs($maxLinesBefore) : 0}]
  set maxLinesAfter [expr {($maxLinesAfter > 0) ? $maxLinesAfter : 0}]
  set numFields [llength $fields]
  set totalLines 0
  set results {}

  foreach $fields [db eval $sql] {
    set match [lmap field $fields {set $field}]
    lassign {{} {}} before after
    set matchId $id
    set matchLines 1
    foreach {context cteContext} {before cteContextBefore after cteContextAfter} {
      set cols [cols $fields context "'$context'"]
      set sql "[WITH cteInput cteRecords cteMatch $cteContext]\
        SELECT $cols FROM $cteContext $WHERE ORDER BY id LIMIT :v::maxResults - 1"
      set $context [db eval $sql]
      incr matchLines [expr {[llength [set $context]] / $numFields}]
    }
    if {($totalLines + $matchLines) <= $v::maxResults} {
      lappend results {*}[concat $before $match $after]
      incr totalLines $matchLines
    }
    if {$totalLines >= $v::maxResults} {
      break
    }
  }

  return $results
}

proc ::chanlog::searchChanLog {unick host handle dest text {idx -1} {offset 0}} {
  set ret [expr {$offset ? 1 : [::log::logStackable $unick $host $handle $dest $text]}]
  set cmd [lindex [split $text] 0]
  set query [string trim [join [lrange [split $text] 1 end]]]
  set args [list $unick $host $handle $dest $text $idx]
  set searchId "$unick!$host@$dest"

  if {[regexp {^\.+logn(?:ext)?$} $cmd]} {
    if {[info exists v::nextResults($searchId)]} {
      searchChanLog {*}$v::nextResults($searchId)
    } else {
      post $idx msg $dest "You have to search for something first. For options, type .log"
    }
    return $ret
  }

  if {[regexp -nocase {^\.+log\s*$} $text] || ![regexp -nocase {^\.+log[-+=]?(?:\d+)?(?:,[^,\s]+)*$} $cmd]} {
    post $idx msend $unick $dest $v::usage
    return $ret
  }

  set fmt {%d [%s] <%s%s> %s}
  set fields {id date flag nick message context}
  if {[string match ..* $cmd]} { ;# verbose output
    set fmt {%d [%s] <%s%s!%s> %s}
    set fields {id date flag nick userhost message context}
  }

  set results [query $text $fields $offset]
  set results [formatDates $results $fields]
  set numFields [llength $fields]
  set numMessages [expr {[llength $results] / $numFields}]
  set numMatches [llength [lsearch -all -not -regexp [lmap $fields $results {set context}] {before|after}]]
  set hasContextLines [expr {$numMessages > $numMatches}]
  set maxId [tcl::mathfunc::max 0 {*}[lmap $fields $results {set id}]]
  set fmt [regsub {^%} $fmt "\&-[string length $maxId]"]
  set messages {}

  foreach $fields $results {
    set msg [format $fmt {*}[lmap field $fields {set $field}]]
    if {$hasContextLines} {
      switch -- $context {
        before  { set msg "- $msg" }
        after   { set msg "+ $msg" }
        default { set msg [regsub {^.+?>} "= $msg" "\002&\002"] }
      }
    }
    lappend messages $msg
  }

  if {$numMessages > 0} {
    if {$numMessages > $v::maxPublic} {
      post $idx msend $unick $dest $messages
    } else {
      post $idx mpost $dest $messages
    }
    set v::nextResults($searchId) [lappend args [expr {$offset + $numMatches}]]
  } else {
    unset -nocomplain v::nextResults($searchId)
    if {$offset > 0} {
      post $idx msg $dest "No more search results."
    } else {
      post $idx msg $dest "No matches. For more search options, type .log"
    }
  }

  return $ret
}
::irc::mbind {pubm} - {"% .log*" "% ..log*"} ::chanlog::searchChanLog
::irc::mbind {msgm} n {"% .log*" "% ..log*"} ::chanlog::searchChanLog

proc ::chanlog::dccSearchChanLog {handle idx text} {
  searchChanLog $handle dcc $handle $idx $text $idx
  return 0
}
bind dcc n l ::chanlog::dccSearchChanLog

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

proc ::chanlog::post {idx func args} {
  if {$idx == -1} {
    return [$func {*}$args]
  }
  if {$func eq "msg"} {
    return [putdcc $idx [lindex $args end]]
  }
  foreach line [lindex $args end] {
    putdcc $idx $line
  }
  return 1
}

proc ::chanlog::formatDates {results fields} {
  set dateFormat "%m/%d %I:%M:%S %p"
  set currentYear [clock format [clock scan now] -format "%Y"]
  foreach $fields $results {
    if {[clock format [clock scan $date] -format "%Y"] ne $currentYear} {
      set dateFormat "%m/%d/%Y %I:%M:%S %p"
      break
    }
  }
  return [join [lmap $fields $results {
    set date [clock format [clock scan $date] -format $dateFormat]
    set date [string tolower [regsub { 0} $date "  "]]
    lmap field $fields {set $field}
  }]]
}
