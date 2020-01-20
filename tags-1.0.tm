::tcl::tm::path add [file dirname [info script]]

package require irc
package require log
package require database

namespace eval ::tags {
  namespace import ::irc::msg ::irc::send ::irc::msend ::database::loadDatabase
}
namespace eval ::tags::v {
  variable database "tags.db"
  variable dbSetupScript "tags.sql"
}

variable ::tags::v::usage {
  {Usage: .[.][-+#][tag] [message]}
  {.+boom OUT COLD => Create trigger .#boom}
  {.#boom          => Prints 'OUT COLD'}
  {.-boom          => Remove trigger .#boom}
  {.+ some text    => Quotes text without an explicit hash trigger}
  {.#              => Prints random quote}
  {.# ufc          => Prints random quote that contains 'ufc'}
  {..#boom         => Prints verbose version of .#boom with metadata}
  {..#             => Prints this usage help}
  {End of usage.}
}

proc ::tags::init {{database ""}} {
  set dbFile [expr {$database eq "" ? $v::database : $database}]
  loadDatabase ::tags::db $dbFile $v::dbSetupScript
}

proc ::tags::sanitizeQuery {text} {
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

proc ::tags::addTag {unick uhost handle channel text} {
  set ret [::log::logStackable $unick $uhost $handle $channel $text]
  set tag [string range [lindex [split $text] 0] 2 end]
  set message [string trim [join [lrange [split $text] 1 end]]]
  set currentMsg ""

  if {$message eq ""} {
    msend $unick $channel $v::usage
    return $ret
  }

  if {$tag ne ""} {
    set currentMsg [db onecolumn {SELECT message FROM tags WHERE tag = :tag}]
  }
  if {$currentMsg eq ""} {
    set date [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set sql {
      INSERT INTO tags (date, nick, userhost, tag, message)
        VALUES (:date, :unick, :uhost, :tag, :message)
    }
    if {$tag eq ""} {
      set sql {
        INSERT INTO tags (date, nick, userhost, message)
          VALUES (:date, :unick, :uhost, :message)
      }
    }

    db eval $sql

    if {[db changes] > 0} {
      if {$tag eq ""} {
        set msg "Added message with no explicit tag.\
          To display it, use .# to search for it."
      } else {
        set msg "Added tag. Type .#$tag to display it."
      }
    } else {
      set msg "Failed to add #$tag \[[db errorcode]\]"
      putloglev d * $msg
    }    
  } else {
    set msg "Tag #$tag already exists: $currentMsg"
  }

  send $unick $channel $msg
  return $ret
}
::irc::mbind pubm - {"% .+?*"} ::tags::addTag

proc ::tags::removeTag {unick uhost handle channel text} {
  set ret [::log::logStackable $unick $uhost $handle $channel $text]
  set tag [string range [lindex [split $text] 0] 2 end]
  set msg "Failed to find #$tag."

  db eval {SELECT nick, userhost FROM tags WHERE tag = :tag} {
    if {$uhost eq $userhost || [matchattr $handle +n|+n $channel]} {
      db eval {DELETE FROM tags WHERE tag = :tag}
      if {[db changes] > 0} {
        set msg "Deleted #$tag."
      } else {
        set msg "DELETE operation for #$tag failed \[[db errorcode]\]"
        putloglev d * $msg
      }
    } else {
      set msg "You do not have permission to delete #$tag.\
        This tag was added by $nick!$userhost.\
        Try again with a matching userhost,\
        or ask a bot owner to delete it for you."
    }
  }

  send $unick $channel $msg
  return $ret
}
::irc::mbind pubm - {"% .-?*"} ::tags::removeTag

proc ::tags::findTag {unick uhost handle channel text} {
  set ret [::log::logStackable $unick $uhost $handle $channel $text]
  set cmd [lindex [split $text] 0]
  set query [string trim [join [lrange [split $text] 1 end]]]
  set verbose [string match ..* $cmd]
  set tag [string range [string trimleft $cmd .] 1 end]

  set cols "tag, message"
  if {$verbose} {
    if {$tag eq "" && $query eq ""} {
      msend $unick $channel $v::usage
      return $ret
    }
    set cols "id, date, nick, userhost, tag, message"
  }
  if {$tag ne ""} {
    set sql "SELECT $cols FROM tags WHERE tag = :tag"
  } elseif {$query eq ""} {
    set sql "SELECT $cols FROM tags ORDER BY RANDOM() LIMIT 1"
  } else {
    set query [sanitizeQuery $query]
    set sql "SELECT $cols FROM tags_fts WHERE tags_fts MATCH (:query) ORDER BY RANDOM() LIMIT 1"
  }

  db eval $sql {
    if {$verbose} {
      msg $channel "#$tag =$id Added: $date By: $nick!$userhost : $message"
    } else {
      msg $channel "#$tag : $message"
    }
  }
  return $ret
}
::irc::mbind pubm - {"% .#*"}  ::tags::findTag
::irc::mbind pubm - {"% ..#*"} ::tags::findTag

return
