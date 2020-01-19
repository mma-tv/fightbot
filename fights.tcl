####################################################################
#
# File: fights.tcl
#
# Description:
#   MMA/Boxing fight logger and polling script for Eggdrop bots.
#
# Author: makk@EFnet
# Contributors: wims@EFnet
#
# Release Date: May 14, 2010
#  Last Update: Jan 19, 2020
#
# Requirements: Eggdrop 1.6.16+, TCL 8.5+, SQLite 3.6.19+
#
####################################################################

::tcl::tm::path add [file dirname [info script]]

package require bot
package require irc
package require log
package require date
package require database
package require formatter
package require ctrlCodes
package require sherdog
package require bestfightodds
package require chanlog

namespace eval ::fights {

namespace import ::bot::* ::irc::* ::date::* ::database::*
namespace import ::ctrlCodes::* ::formatter::* ::log::logStackable

variable botTitle      "[b][u]FIGHT POLL[/u][/b]"

variable database        "fights.db"   ;# database file
variable sqlScript       "fights.sql"  ;# SQL script file to create database
variable chanFlag        "fights"      ;# channel flag to enable polling
variable adminFlag       "P|P"         ;# user flag for allowing poll administration
variable minPickDateDiff 2             ;# allow picks up to this many hours before event starts
variable pollDuration    15            ;# max minutes before polling automatically ends
variable pollInterval    120           ;# send reminders every this many seconds during polling
variable maxResults      20            ;# max command results to show at one time
variable backupTime      "04:44"       ;# military time of day to perform daily backup
variable updateTime      "03:33"       ;# military time of day to update upcoming events from web
variable minBestPicks    5             ;# min number of picks to qualify for winning Best Picker
variable maxPublicLines  5             ;# limit number of lines that can be dumped to channel
variable defaultColSizes {* * * 19 3 * 0} ;# default column widths for .sherdog output

variable scriptVersion "1.6.4"
variable ns [namespace current]
variable poll
variable pollTimer
variable users
variable imports

setudef flag $chanFlag


proc init {} {
    variable ns
    variable poll
    variable users
    variable database
    variable sqlScript
    variable backupTime

    endPoll

    unset -nocomplain poll users

    if {[info commands ${ns}::db] eq ""} {
        if {[catch {loadDatabase ${ns}::db $database [list $sqlScript]} error]} {
            return -code error $error
        }
        catch {db function STREAK ${ns}::streakSQL}

        if {[catch {db eval {SELECT * FROM vw_stats LIMIT 1}} error]} {
            return -code error "*** Database integrity test failed: $error"
        }
        bindSQL "sqlfights" ${ns}::db
        scheduleBackup ${ns}::db $database $backupTime $::irc::debugLogLevel
    }

    ::chanlog::init
    return 0
}

proc onPollChan {unick} {
    variable chanFlag
    foreach chan [channels] {
        if {[channel get $chan $chanFlag] && [onchan $unick $chan]} {
            return 1
        }
    }
    return 0
}

proc mmsg {messages {title ""}} {
    variable chanFlag
    variable botTitle
    set title [expr {$title eq "" ? $botTitle : "$botTitle :: $title"}]
    foreach chan [channels] {
        if {[channel get $chan $chanFlag]} {
            msg $chan $title
            foreach message $messages {
                msg $chan $message
            }
        }
    }
}

proc getNumFormat {maxNumber} {
    return "%[string length $maxNumber]d"
}

proc getUser {unick host args} {
    return [string toupper $unick]
}

proc clearEvents {unick host} {
    variable users
    array unset users "[getUser $unick $host],event,*"
}

proc clearEvent {unick host {eventIndex -1}} {
    variable users
    set key "[getUser $unick $host],event"
    if {$eventIndex == -1 && [info exists users($key,selection)]} {
        set eventIndex $users($key,selection)
    }
    array unset users "$key,$eventIndex,*"
}

proc setEvent {unick host eventIndex eventId eventName eventDate} {
    variable users
    if {$eventIndex > 0} {
        set key "[getUser $unick $host],event,$eventIndex"
        set users($key,index) $eventIndex
        set users($key,id) $eventId
        set users($key,name) $eventName
        set users($key,date) $eventDate
        return 1
    }
    return 0
}

proc getEvent {unick host dest eventData {eventIndex -1}} {
    variable users
    set user [getUser $unick $host]
    if {$eventIndex == -1 && [info exists users($user,event,selection)]} {
        set eventIndex $users($user,event,selection)
    }
    set key "$user,event,$eventIndex"
    if {[info exists users($key,index)]} {
        upvar $eventData data
        foreach subkey {index id name date} {
            set data($subkey) $users($key,$subkey)
        }
        return 1
    }
    send $unick $dest "Type [b].event[/b] for a list of events, then [b].event <index>[/b] to select one."
    return 0
}

proc selectEvent {unick host dest index} {
    variable users
    set index [string trim $index]
    if {[string is digit -strict $index] && [getEvent $unick $host $dest event $index]} {
        set users([getUser $unick $host],event,selection) $index
        return 1
    }
    return 0
}

proc setFight {unick host eventIndex fightIndex fightId fighter1 fighter2} {
    variable users
    if {$eventIndex > 0 && $fightIndex > 0} {
        set key "[getUser $unick $host],event,$eventIndex,$fightIndex"
        set users($key,index) $fightIndex
        set users($key,id) $fightId
        set users($key,fighter1) $fighter1
        set users($key,fighter2) $fighter2
        set users($key,event) $eventIndex
        return 1
    }
    return 0
}

proc clearFights {unick host} {
    variable users
    set key "[getUser $unick $host],event"
    if {[info exists users($key,selection)]} {
        append key ",$users($key,selection)"
        regsub -all {\W} $key {\\&} key
        foreach item [array names users -regexp "$key,\\d+"] {
            unset users($item)
        }
    }
}

proc getFight {unick host dest fightData {fightIndex -1}} {
    variable users
    if {[getEvent $unick $host $dest event]} {
        set user [getUser $unick $host]
        if {$fightIndex == -1 && [info exists users($user,event,$event(index),selection)]} {
            set fightIndex $users($user,event,$event(index),selection)
        }
        set key "$user,event,$event(index),$fightIndex"
        if {[info exists users($key,index)]} {
            upvar $fightData data
            foreach subkey {index id fighter1 fighter2 event} {
                set data($subkey) $users($key,$subkey)
            }
            return 1
        }
        send $unick $dest "There is no fight for $event(name) with index [b]$fightIndex[/b].\
            Type [b].fights[/b] to list the lineup again."
    }
    return 0
}

proc selectFight {unick host dest index {eventIndex -1}} {
    variable users
    set index [string trim $index]
    set eventIndex [string trim $eventIndex]
    if {[string is digit -strict $index] && [getEvent $unick $host $dest event $eventIndex]\
            && [getFight $unick $host $dest fight $index]} {
        set users([getUser $unick $host],event,$event(index),selection) $index
        return 1
    }
    return 0
}

proc importFights {} {
    if {![bestfightodds::import events err]} {
        putlog "Failed to import fights: $err"
        return false
    }

    foreach eventInfo $events {
        dict with eventInfo {
            if {[db eval {INSERT OR IGNORE INTO events (name, start_date) VALUES(:event, :date)}]} {
                set eventId [db last_insert_rowid]
            } else {
                db eval {UPDATE events SET name = :event WHERE name = :event}
                set eventId [db onecolumn {SELECT id FROM events WHERE name = :event}]
            }
            foreach fight $fights {
                dict with fight {
                    if {![db eval {
                        INSERT OR IGNORE INTO fights (event_id, fighter1, fighter2, fighter1_odds, fighter2_odds)
                            VALUES(:eventId, :fighter1, :fighter2, :odds1, :odds2)}]
                    } {
                        db eval {
                            UPDATE fights SET fighter1 = :fighter1, fighter2 = :fighter2,
                                fighter1_odds = :odds1, fighter2_odds = :odds2
                                WHERE event_id = :eventId AND fighter1 = :fighter1 AND fighter2 = :fighter2
                        }
                    }
                }
            }
        }
    }

    return true
}

proc importFightsJob {minute hour day month year} {
    importFights
}
bind time - "[lindex [split $updateTime :] 1] [lindex [split $updateTime :] 0] * * *" ${ns}::importFightsJob

proc importFightsTrigger {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }
    send $unick $dest "Importing fights. Please wait..."
    if {[importFights]} {
        send $unick $dest "Import completed successfully."
    } else {
        send $unick $dest "Import failed. See log for details."
    }
    return 1
}
mbind {msg pub} $adminFlag {.import .importfights .importevents} ${ns}::importFightsTrigger

proc setTimeZone {unick host handle dest timezone} {
    if {![onPollChan $unick]} { return 0 }

    set tz [string trim $timezone]
    if {$tz eq ""} {
        send $unick $dest "Usage: .tz <timezone>"
    } else {
        foreach zone [list $tz ":$tz" [string toupper $tz] [string toupper ":$tz"]] {
            if {![catch {set currentTime [clock format [unixtime] -format "%b %e, %Y %l:%M%P" -timezone $zone]}]} {
                if {[db eval {UPDATE users SET timezone = :zone WHERE nick = :unick}]} {
                    regsub -all {\s{2,}} $currentTime " " currentTime
                    send $unick $dest "Your time zone has been set to [b]$zone[/b].\
                        The current time should be $currentTime."
                }
                return 1
            }
        }
        send $unick $dest "There was an error setting the time zone you specified.\
            Common US time zones are: US/Eastern US/Central US/Mountain US/Pacific"
    }
    return 1
}
mbind {msg pub} - {.tz .timezone} ${ns}::setTimeZone

proc getLimits {text outTrigger outOffset outLimit outArgs} {
    variable maxResults

    upvar $outTrigger trigger $outOffset offset $outLimit limit $outArgs args

    set trigger [lindex [split $text] 0]
    set offset 0
    set limit $maxResults
    set args [string trim [join [lrange [split $text] 1 end]]]

    if {[regexp {^(\S+?)(?:(-?\d+)(?:,(-?\d+))?)?$} $trigger m trigger offset limit]} {
        set offset [expr {[string is digit -strict $offset] ? $offset : 0}]
        set limit [expr {[string is digit -strict $limit] ? min($limit, $maxResults) : $maxResults}]
        return 1
    }
    return 0
}

proc listEvents {unick host handle dest text} {
    if {![onPollChan $unick]} { return 1 }

    getLimits $text trigger offset limit expr

    # treat .events as .event if the search string is a valid event index
    if {$trigger eq ".events" && [selectEvent $unick $host "" $expr]} {
        listFights $unick $host $handle $dest
        return [logStackable $unick $host $handle $dest $text]
    }

    clearEvents $unick $host

    set query {SELECT id, name, start_date FROM events}
    if {$expr eq ""} {
        lappend query WHERE locked = 0 AND start_date > (DATETIME(JULIANDAY() - 1)) ORDER BY start_date, name
    } else {
        lappend query WHERE name REGEXP :expr ORDER BY start_date, name
    }
    lappend query LIMIT :offset, :limit

    set events [db eval $query]

    set totalEvents [expr {[llength $events] / 3}]
    if {$totalEvents} {
        set tzNotice "\[ all times are [timezone 1] \]"
        if {$expr eq ""} {
            send $unick $dest "[b][u]UPCOMING EVENTS[/u][/b]  $tzNotice"
        } else {
            send $unick $dest "Found [b]$totalEvents[/b] event[s $totalEvents] matching '$expr':  $tzNotice"
        }
        set numFormat [getNumFormat $totalEvents]
        set index 0
        foreach {eventId eventName eventDate} $events {
            incr index
            setEvent $unick $host $index $eventId $eventName $eventDate
            set eventItem [format "[b]$numFormat[/b]. [b]%s[/b]" $index $eventName]
            if {$eventName ne "Future Events" && $eventDate ne ""} {
                append eventItem " - [formatWordDateTime $eventDate 0] ([timeDiff $eventDate])"
            }
            send $unick $dest $eventItem
        }
        if {$totalEvents == $limit} {
            send $unick $dest "For the next $limit results, type: [b]$trigger[expr {$offset + $limit}] $expr[/b]"
        }
        if {$expr eq ""} {
            send $unick $dest "To search for an event, type: [b].findevent <eventRE>[/b]"
        }
        send $unick $dest "To select an event, type: [b].event <index>[/b]"
    } elseif {$offset > 0} {
        send $unick $dest "No more events."
    } else {
        send $unick $dest "No events found."
    }
    if {$text eq ""} {
        return 1
    }
    return [logStackable $unick $host $handle $dest $text]
}
mbind {msgm pubm} - {"% .events*" "% .findevent*"} ${ns}::listEvents

proc event {unick host handle dest index} {
    if {![onPollChan $unick]} { return 0 }

    if {[selectEvent $unick $host "" $index]} {
        listFights $unick $host $handle $dest
    } else {
        listEvents $unick $host $handle $dest ".events"
        if {$index ne ""} {
            send $unick $dest " "
            send $unick $dest "The upcoming events list was reloaded.\
                Verify your selection above and try again."
        }
        return 0
    }
    return 1
}
mbind {msg pub} - .event ${ns}::event

proc addEvent {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    if {![regexp {^\s*([^;]+?)\s*(?:;\s*(.+?)\s*)?$} $text m eventName eventDate]} {
        send $unick $dest {Usage: .addevent <event>[; yyyy-MM-dd HH:mm Z]}
    } else {
        set defaultDate 0
        regsub -all -nocase {\s*@\s*|\s+at\s+} $eventDate " " eventDate
        if {$eventDate eq "" || [catch {set eventDate [toGMT $eventDate]}]} {
            set eventDate [now]
            set defaultDate 1
        }
        if {[db eval {
            INSERT OR IGNORE INTO events (name, start_date)
                VALUES(:eventName, :eventDate)}]
        } {
            set eventId [db last_insert_rowid]
            send $unick $dest "Added event [b]$eventName[/b] to be held on\
                [formatWordDateTime $eventDate] [timezone]."
        } elseif {[db eval {
            UPDATE events SET name = :eventName, start_date = :eventDate, locked = 0
                WHERE name = :eventName}]
        } {
            set eventId [db onecolumn {SELECT id FROM events WHERE name = :eventName}]
            send $unick $dest "Updated event [b]$eventName[/b] to be held on\
                [formatWordDateTime $eventDate] [timezone]."
        }
        if {[info exists eventId]} {
            clearEvents $unick $host
            setEvent $unick $host 1 $eventId $eventName $eventDate
            selectEvent $unick $host $dest 1

            if {$defaultDate} {
                send $unick $dest "Since you did not specify a valid event date, the event has been\
                    scheduled for today by default. This means users are not allowed to [b].pick[/b]\
                    for this event and can only vote during the live fight announcements."
                send $unick $dest "You can change the date at any time by typing:\
                    [b].addevent $eventName; yyyy-MM-dd HH:mm Z[/b]"
            }
        }
    }
    return 1
}
mbind {msg pub} $adminFlag .addevent ${ns}::addEvent

proc delEvent {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    variable poll
    if {![regexp {^\s*(-f(?:orce)?\s+)?(\d+)\s*$} $text m force index]} {
        send $unick $dest {Usage: .delevent [-f] <index>}
    } elseif {[getEvent $unick $host $dest event $index]} {
        if {$force eq ""} {
            send $unick $dest "Are you sure you want to delete [b]$event(name)[/b]?\
                This will permanently remove all fights and votes associated with this event."
            send $unick $dest "To proceed, type: [b].delevent -f $index[/b]"
        } elseif {[db eval {DELETE FROM events WHERE id = :event(id)}]} {
            if {[getEvent $unick $host "" selectedEvent] && $selectedEvent(id) == $event(id)} {
                clearEvent $unick $host
            }
            array unset poll "$event(id),lastpoll"
            if {[info exists poll(current)] && [lindex [split $poll(current) ","] 0] == $event(id)} {
                endPoll
            }
            send $unick $dest "'$event(name)' event has been deleted."
        } else {
            send $unick $dest "'$event(name)' event does not exist."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag .delevent ${ns}::delEvent

proc renameEvent {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    set index [lindex $text 0]
    set eventName [string trim [join [lrange $text 1 end]]]
    if {![string is digit -strict $index] || $eventName eq ""} {
        send $unick $dest {Usage: .renameevent <index> <newEventName>}
    } elseif {[getEvent $unick $host $dest event $index]} {
        if {[catch {db eval {UPDATE events SET name = :eventName WHERE id = :event(id)}}]} {
            send $unick $dest "Rename operation failed.\
                Either \"$event(name)\" no longer exists or an event named \"$eventName\" already exists."
        } else {
            send $unick $dest "Renamed \"$event(name)\" to [b]$eventName[/b]."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag {.renameevent .renamevent} ${ns}::renameEvent

proc mergeEvents {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    if {![regexp {^\s*(-f(?:orce)?\s+)?(\d+)\s+(\d+)} $text m force oldEventIndex newEventIndex]
            || $oldEventIndex == $newEventIndex} {
        send $unick $dest {Usage: .mergeevents [-f] <oldEventIndex> <newEventIndex>}
    } elseif {[getEvent $unick $host $dest oldEvent $oldEventIndex]
                && [getEvent $unick $host $dest newEvent $newEventIndex]} {
        if {$force eq ""} {
            foreach line [list\
                    "Are you sure you want to merge these two events?  This will:"\
                    "1) Permanently delete the existing '[b]$newEvent(name)[/b]' event,"\
                    "2) Rename '[b]$oldEvent(name)[/b]' to '[b]$newEvent(name)[/b]', and"\
                    "3) Reimport fights from bestfightodds.com."\
                    "To proceed, type: [b].mergeevents -f $oldEventIndex $newEventIndex[/b]"] {
                send $unick $dest $line
            }
        } else {
            catch {db eval {DELETE FROM events WHERE id = :newEvent(id)}}
            catch {db eval {UPDATE events SET name = :newEvent(name) WHERE id = :oldEvent(id)}}
            importFights
            send $unick $dest "Events are now merged into '[b]$newEvent(name)[/b]'."
        }
    } else {
        send $unick $dest {At least one event index you provided is invalid. Check the event listing and try again.}
    }
    return 1
}
mbind {msg pub} $adminFlag {.mergeevent .mergeevents .mergevent .mergevents} ${ns}::mergeEvents

proc setMainEvent {unick host handle dest index} {
  if {![onPollChan $unick]} { return 0 }

  set index [string trim $index]
  if {![string is digit -strict $index]} {
    send $unick $dest "Usage: .setmainevent <index>"
  } elseif {[getEvent $unick $host $dest event] && [getFight $unick $host $dest fight $index]} {
    if {[db eval {UPDATE events SET main_event = :fight(id) WHERE id = :event(id)}]} {
      send $unick $dest "Main event set to $fight(fighter1) vs. $fight(fighter2)."
      listFights $unick $host $handle $dest
    } else {
      send $unick $dest "Failed to set main event for $event(name)."
    }
  }
  return 1
}
mbind {msg pub} $adminFlag {.setmainevent} ${ns}::setMainEvent

proc unsetMainEvent {unick host handle dest text} {
  if {![onPollChan $unick]} { return 0 }

  if {[getEvent $unick $host $dest event]} {
    if {[db eval {UPDATE events SET main_event = NULL WHERE id = :event(id)}]} {
      send $unick $dest "Unset main event for $event(name)."
      listFights $unick $host $handle $dest
    }
  }
  return 1
}
mbind {msg pub} $adminFlag {.unsetmainevent} ${ns}::unsetMainEvent

proc endEvent {unick host handle dest text} {
    if {[getEvent $unick $host $dest event]} {
        if {[db eval {UPDATE events SET locked = 1 WHERE id = :event(id)}]} {
            send $unick $dest "[b]$event(name)[/b] has ended and is no longer accepting votes."
        } else {
            send $unick $dest "[b]$event(name)[/b] does not exist or was not open for voting."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag {.endevent} ${ns}::endEvent

proc getNotes {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    set id [lindex [split [string trim $text]] 0]
    set event(id) $id
    if {($id eq "" && ![getEvent $unick $host "" event])
            || ![string is digit -strict $event(id)]} {
        send $unick $dest "You must either specify an explicit event ID with\
            [b].notes <id>[/b] or first select an event with [b].event <index>[/b]."
    } else {
        db eval {SELECT name, start_date AS date, notes FROM events WHERE id = :event(id)} r {}
        if {[array size r] > 1} {
            set title "[b]$r(name)[/b] ([formatShortDate $r(date)])"
            if {$r(notes) eq ""} {
                send $unick $dest "There are no notes set for $title."
            } else {
                send $unick $dest "Notes for $title:"
                send $unick $dest $r(notes)
                if {$id eq ""} {
                    send $unick $dest "Direct access: [b].notes $event(id)[/b]"
                }
            }
        } else {
            send $unick $dest "There are no notes for that event because it does not exist\
                -- it may have been deleted."
        }
    }
    return 1
}
mbind {msg pub} - {.note .notes} ${ns}::getNotes

proc setNotes {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    set text [string trim $text]
    if {$text eq ""} {
        getNotes $unick $host $handle $dest $text
        send $unick $dest "Usage: .setnotes <text>"
    } elseif {[getEvent $unick $host $dest event]} {
        if {[db eval {UPDATE events SET notes = :text WHERE id = :event(id)}]} {
            send $unick $dest "Your notes have been set and are viewable under this event listing."
            send $unick $dest "Direct access: [b].notes $event(id)[/b]"
        } else {
            send $unick $dest "Failed to set notes for this event -- it may have been deleted."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag {.setnote .setnotes} ${ns}::setNotes

proc clearNotes {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    if {[getEvent $unick $host $dest event]} {
        if {[db eval {UPDATE events SET notes = NULL WHERE id = :event(id)}]} {
            send $unick $dest "Notes cleared."
        } else {
            send $unick $dest "Failed to clear notes for this event -- it may have been deleted."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag {.clearnote .clearnotes} ${ns}::clearNotes

proc announceEvent {unick host handle dest text} {
    global botnick
    variable minPickDateDiff
    if {[getEvent $unick $host $dest event]} {
        mmsg [list "Now accepting fight picks for [b]$event(name)[/b] to be held\
            on [formatWordDateTime $event(date)]. You can use [b].pick[/b] to make your\
            picks up to $minPickDateDiff hour[s $minPickDateDiff] before the event.\
            As usual, you'll also be able to cast your vote during the live fight announcements.\
            Type [b].help[/b] for a full list of options."] $event(name)
    }
    return 1
}
mbind {msg pub} $adminFlag {.sayevent} ${ns}::announceEvent

proc listFights {unick host handle dest {text ""} {showUsage 0}} {
    if {![onPollChan $unick]} { return 0 }

    variable adminFlag
    if {[getEvent $unick $host $dest event]} {
        clearFights $unick $host

        set user [expr {$text eq "" ? $unick : [string trim $text]}]
        set you [string equal -nocase $user $unick]
        set rows [db eval {
            SELECT fights.id, fighter1, fighter2, fighter1_odds, fighter2_odds,
                fights.result, notes, locked, pick, vote FROM fights
                LEFT JOIN picks ON fights.id = picks.fight_id
                AND picks.user_id IN(SELECT id FROM users WHERE nick = :user)
                WHERE event_id = :event(id) ORDER BY fights.id;
        }]
        set totalFights [expr {[llength $rows] / 10}]
        if {$totalFights} {
            set mainEvent [getMainEvent $event(id)]
            set numFormat [getNumFormat $totalFights]
            set lines {}
            set totalPicks 0
            set index 0

            foreach {fightId fighter1 fighter2 odds1 odds2 result notes locked pick vote} $rows {
                incr index
                setFight $unick $host $event(index) $index $fightId $fighter1 $fighter2
                set resultId -1
                if {$result ne ""} {
                    set resultId 0
                    if {[string equal -nocase $fighter1 $result]} {
                        set resultId 1
                    } elseif {[string equal -nocase $fighter2 $result]} {
                        set resultId 2
                    }
                }
                set mark ""
                if {$vote ne ""} {
                    set mark [expr {$vote ? "*" : "~"}]
                }
                if {[string equal -nocase $pick $fighter1]} {
                    set fighter1 "[b]$fighter1$mark[/b]"
                    incr totalPicks
                } elseif {[string equal -nocase $pick $fighter2]} {
                    set fighter2 "[b]$fighter2$mark[/b]"
                    incr totalPicks
                }
                set other ""
                set result1 ""
                set result2 ""
                switch $resultId {
                    0 {set other " ([string range $result 1 end])"}
                    1 {set result1 " (W)"; set result2 " (L)"}
                    2 {set result1 " (L)"; set result2 " (W)"}
                }

                if {$odds1 ne ""} {
                    set odds1 [format " <[expr {$odds1 == 0 ? "EV" : "%+d"}]>" $odds1]
                }
                if {$odds2 ne ""} {
                    set odds2 [format " <[expr {$odds2 == 0 ? "EV" : "%+d"}]>" $odds2]
                }

                set sep [expr {$mainEvent == $fightId ? "[u].[/u]" : "."}]
                set resultLine [format "[b]$numFormat[/b]%s %s%s%s vs. %s%s%s%s"\
                    $index $sep $fighter1 $odds1 $result1 $fighter2 $odds2 $result2 $other]
                if {$locked} {
                    set message ""
                    if {$resultId == -1} {
                        set message "PENDING RESULTS"
                    }
                    if {$notes ne "" && $message ne ""} {
                        append resultLine " :: \[ $notes | $message \]"
                    } elseif {"$notes$message" ne ""} {
                        append resultLine " :: \[ $notes$message \]"
                    }
                }
                lappend lines $resultLine
            }
            set picks ""
            if {$you} {
                set who "Your"
            } else {
                set who "[b]$user's[/b]"
            }
            if {$totalPicks == 1} {
                set picks "* $who pick is marked in bold."
            } elseif {$totalPicks > 1} {
                set picks "* $who $totalPicks picks are marked in bold."
            } elseif {!$you} {
                set picks "* [b]$user[/b] has not made any picks for this event."
            }

            send $unick $dest "[b]$event(name)[/b] has the following [b]$totalFights[/b] fight[s $totalFights] (A vs. B):"
            if {$picks ne ""} {
                send $unick $dest $picks
            }
            foreach line $lines {
                send $unick $dest $line
            }
            if {($totalPicks == 0 && $you) || $showUsage} {
                send $unick $dest "Type [b].pick <index><a|b>\[~\][/b] to make your picks. Multi-pick example: .pick 1b 2a~ 4b"
                send $unick $dest "Picks with a tilde '~' after them will not affect your stats."
            }
        } else {
            set message "No fights have yet been added for the [b]$event(name)[/b] event."
            if {[matchchanattr $handle $adminFlag $dest]} {
                append message "  To manually add fights, type: [b].addfight <fighter1> vs <fighter2>[/b]"
            }
            send $unick $dest $message
        }
        set notes [db onecolumn {SELECT notes FROM events WHERE id = :event(id)}]
        if {$notes ne ""} {
            send $unick $dest "[b]*[/b] $notes"
        }
    }
    return 1
}
mbind {msg pub} - {.fights} ${ns}::listFights

proc addFight {unick host handle dest fight} {
    if {![onPollChan $unick]} { return 0 }

    if {[getEvent $unick $host $dest event]} {
        if {![regexp -nocase\
                {^\s*(.+?)(?:\s+<([-+]\d+|EV(?:EN)?)>)?(?:\s+vs?\.?\s+|\s*;\s*)(.+?)(?:\s+<([-+]\d+|EV(?:EN)?)>)?\s*$}\
                $fight m fighter1 odds1 fighter2 odds2]} {
            send $unick $dest "Usage: .addfight fighter1 [<+-odds1>] vs fighter2 [<+-odds2>]"
        } else {
            regsub -all {\s{2,}} $fighter1 " " fighter1
            regsub -all {\s{2,}} $fighter2 " " fighter2
            if {[string toupper [string index $odds1 0]] eq "E"} {
                set odds1 0
            }
            if {[string toupper [string index $odds2 0]] eq "E"} {
                set odds2 0
            }
            if {[db eval {
                    INSERT OR IGNORE INTO fights (event_id, fighter1, fighter2, fighter1_odds, fighter2_odds)
                        VALUES(:event(id), :fighter1, :fighter2, :odds1, :odds2)
            }]} {
                send $unick $dest "[b]$fighter1[/b] vs. [b]$fighter2[/b] has been added to the $event(name) event."
            } elseif {[db eval {
                    UPDATE fights SET fighter1 = :fighter1, fighter2 = :fighter2,
                        fighter1_odds = :odds1, fighter2_odds = :odds2
                        WHERE event_id = :event(id) AND fighter1 = :fighter1 AND fighter2 = :fighter2
            }]} {
                send $unick $dest "'$fight' already existed, but was updated anyway."
            } else {
                send $unick $dest "'$fight' already exists or event '$event(name)' no longer exists."
            }
        }
    }
    return 1
}
mbind {msg pub} $adminFlag .addfight ${ns}::addFight

proc delFight {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    variable poll
    if {![regexp {^\s*(-f(?:orce)?\s+)?(\d+)\s*$} $text m force index]} {
        send $unick $dest {Usage: .delfight [-f] <index>}
    } elseif {[getEvent $unick $host $dest event] && [getFight $unick $host $dest fight $index]} {
        set fighter1 $fight(fighter1)
        set fighter2 $fight(fighter2)
        if {$force eq ""} {
            send $unick $dest "Are you sure you want to delete [b]$fighter1 vs. $fighter2[/b]?\
                This will permanently remove any votes cast for this fight."
            send $unick $dest "To proceed, type: [b].delfight -f $index[/b]"
        } elseif {[db eval {DELETE FROM fights WHERE id = :fight(id)}]} {
            set key "$event(id),$fight(id)"
            array unset poll "$key,*"
            if {[info exists poll($event(id),lastpoll)] && $poll($event(id),lastpoll) == $key} {
                array unset poll "$event(id),lastpoll"
            }
            if {[info exists poll(current)] && $poll(current) == $key} {
                endPoll
            }
            listFights $unick $host $handle $dest
            send $unick $dest "'[b]$fighter1 vs. $fighter2[/b]' has been deleted from $event(name)."
        } else {
            send $unick $dest "'[b]$fighter1 vs. $fighter2[/b]' does not exist for $event(name)."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag .delfight ${ns}::delFight

proc renameFighter {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    if {![regexp -nocase {^\s*(\d+)\s*([ab])\s+(.+?)\s*$} $text m index which fighterName]} {
        send $unick $dest {Usage: .renamefighter <index><a|b> <newFighterName>}
    } elseif {[getEvent $unick $host $dest event] && [getFight $unick $host $dest fight $index]} {
        regsub -all {\s{2,}} $fighterName " " fighterName
        set sql {UPDATE fights SET}
        set who "fighter[expr {$which eq "a" || $which eq "A" ? 1 : 2}]"
        set oldFighterName $fight($who)
        lappend sql $who = :fighterName WHERE id = :fight(id)
        if {[catch {db eval $sql}]} {
            send $unick $dest "Rename operation failed.\
                Either \"$oldFighterName\" no longer exists or a fighter named \"$fighterName\" already exists."
        } else {
            catch {db eval {
                UPDATE picks SET pick = :fighterName WHERE fight_id = :fight(id) AND pick = :oldFighterName;
                UPDATE fights SET result = :fighterName WHERE id = :fight(id) AND result = :oldFighterName;
            }}
            listFights $unick $host $handle $dest
            send $unick $dest "Renamed fighter \"$oldFighterName\" to [b]$fighterName[/b]."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag {.renamefight .renamefighter} ${ns}::renameFighter

proc lockFight {lockState unick host handle dest index} {
    if {![onPollChan $unick]} { return 0 }

    set prefix [expr {$lockState ? "" : "un"}]
    set index [string trim $index]
    if {![string is digit -strict $index]} {
        send $unick $dest "Usage: .${prefix}lock <index>"
    } elseif {[getFight $unick $host $dest fight $index]} {
        set versus "[b]$fight(fighter1) vs. $fight(fighter2)[/b]"
        if {[db eval {UPDATE fights SET locked = :lockState WHERE id = :fight(id)}]} {
            send $unick $dest "$versus is now ${prefix}locked for voting."
        } else {
            send $unick $dest "$versus could not be ${prefix}locked -- it may have been deleted."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag {.lock} [list ${ns}::lockFight 1]
mbind {msg pub} $adminFlag {.unlock} [list ${ns}::lockFight 0]

proc findFights {unick host handle dest query} {
    if {![onPollChan $unick]} { return 0 }

    if {[set query [string trim $query]] eq "" ||
            ![regexp -nocase {^(?:([^@]+?)\s*(?:(?:\svs?\.?\s|;)\s*([^@]+?)\s*)?)?(?:@\s*(.+?)\s*)?$}\
                $query m fighter1 fighter2 event]
    } {
        send $unick $dest {Usage: .findfight [fighter1RE [vs fighter2RE]][@ eventRE]}
    } else {
        set events {}
        set totalFights 0
        db eval {
            SELECT fight_id AS fightId, fighter1, fighter2, result, fight_notes AS notes,
                fight_locked AS locked, event_id AS eventId, event_name AS eventName,
                event_start_date AS eventDate FROM vw_fights WHERE
                ((fighter1 REGEXP :fighter1 AND fighter2 REGEXP :fighter2) OR
                (fighter1 REGEXP :fighter2 AND fighter2 REGEXP :fighter1))
                AND event_name REGEXP :event GROUP BY fight_id ORDER BY event_start_date
        } {
            incr totalFights
            if {[string equal -nocase $result $fighter1]} {
                set fight "[b]$fighter1[/b] defeated $fighter2"
            } elseif {[string equal -nocase $result $fighter2]} {
                set fight "[b]$fighter2[/b] defeated $fighter1"
            } elseif {$result ne ""} {
                set fight "$fighter1 vs. $fighter2 was a [string range $result 1 end]"
            } else {
                set fight "$fighter1 vs. $fighter2"
            }
            if {$notes ne ""} {
                append fight " :: \[ $notes \]"
            }
            if {[lsearch -exact $events $eventName] == -1} {
                lappend events $eventId $eventName $eventDate
            }
            lappend fights($eventName) [list $locked $fightId $fighter1 $fighter2 $fight]
        }
        if {[info exists fights]} {
            clearEvents $unick $host

            set eventCounter 0
            set fightCounter 0
            set numFormat [getNumFormat $totalFights]

            send $unick $dest "Found $totalFights matching fight[s $totalFights]:"
            foreach {eventId eventName eventDate} $events {
                setEvent $unick $host [incr eventCounter] $eventId $eventName $eventDate
                send $unick $dest [format "[b]$numFormat[/b]. [b]%s[/b] on %s:"\
                    $eventCounter $eventName [formatWordDateTime $eventDate]]
                foreach fight $fights($eventName) {
                    foreach {locked fightId fighter1 fighter2 fightText} $fight {
                        set index "-"
                        if {$locked == 0} {
                            setFight $unick $host $eventCounter [incr fightCounter] $fightId $fighter1 $fighter2
                            set index "${fightCounter}."
                        }
                        send $unick $dest [format "%[string length $totalFights]s  - %s" "" $fightText]
                    }
                }
            }
            send $unick $dest "To select an event, type: [b].event <index>[/b]"
        } else {
            send $unick $dest "No fights matched those search criteria '$query'."
        }
    }
    return 1
}
mbind {msg pub} - {.findfight .findfights} ${ns}::findFights

proc vote {fighterId type unick host handle dest text} {
    variable poll
    variable chanFlag

    if {[channel get $dest $chanFlag] && [info exists poll(current)]} {
        set key $poll(current)
        set fightId $poll($key,fightId)
        set voted [expr {$type eq ""}]
        set user [string toupper $unick]
        set pick [list $fighterId $voted $unick $host]
        set fighter [expr {$fighterId == 1 ? $poll($key,fighter1) : $poll($key,fighter2)}]
        if {[info exists poll($key,picks,$user)] && [string equal -nocase $poll($key,picks,$user) $pick]} {
            send $unick $dest "You've already voted [b]!$fighterId$type[/b] for [b]$fighter[/b]."
        } else {
            set poll($key,picks,$user) $pick
            set message "Your vote for [b]$fighter[/b] has been queued for entry."
            if {!$voted} {
                append message "  As you requested, your vote will not count towards your cumulative stats."
            }
            send $unick $dest $message
            return 1
        }
    }
    return 0
}

proc togglePoll {state} {
    variable ns
    catch {
        set bindFunc [expr {$state ? "bind" : "unbind"}]
        $bindFunc pub - !1  [list ${ns}::vote 1 ""]
        $bindFunc pub - !1~ [list ${ns}::vote 1 "~"]
        $bindFunc pub - !2  [list ${ns}::vote 2 ""]
        $bindFunc pub - !2~ [list ${ns}::vote 2 "~"]
    }
}

proc endPoll {} {
    variable poll
    variable pollTimer
    catch {killutimer $pollTimer}
    togglePoll "off"

    if {[info exists poll(current)]} {
        set key $poll(current)
        if {[info exists poll($key,fightId)]} {
            set fightId $poll($key,fightId)
            set fighter1 $poll($key,fighter1)
            set fighter2 $poll($key,fighter2)
            set eventName $poll($key,eventName)

            if {[db eval {UPDATE fights SET start_time = DATETIME(), locked = 1 WHERE id = :fightId}]} {
                foreach user [array names poll "$key,picks,*"] {
                    if {[lindex $poll($user) 0] == 1} {
                        set pick $fighter1
                    } else {
                        set pick $fighter2
                    }
                    set voted [lindex $poll($user) 1]
                    set unick [lindex $poll($user) 2]
                    set host  [lindex $poll($user) 3]
                    db eval {
                        INSERT OR IGNORE INTO users (nick, host) VALUES(:unick, :host);
                        INSERT OR REPLACE INTO picks (user_id, fight_id, pick, vote, pick_date)
                            VALUES((SELECT id FROM users WHERE nick = :unick), :fightId, :pick, :voted, DATETIME());
                    }
                }
                array unset poll "$key,picks,*"

                db eval {
                    SELECT SUM(CASE WHEN pick = :fighter1 THEN 1 ELSE 0 END) AS fighter1Votes,
                           SUM(CASE WHEN pick = :fighter2 THEN 1 ELSE 0 END) AS fighter2Votes
                           FROM picks WHERE fight_id = :fightId
                } {
                    if {$fighter1Votes eq ""} {
                        set fighter1Votes 0
                    }
                    if {$fighter2Votes eq ""} {
                        set fighter2Votes 0
                    }
                    set totalVotes [expr {$fighter1Votes + $fighter2Votes}]
                    if {$totalVotes > 0} {
                        set fighter1Percentage [format "%.0f%%" [expr {($fighter1Votes / double($totalVotes)) * 100}]]
                        set fighter2Percentage [format "%.0f%%" [expr {($fighter2Votes / double($totalVotes)) * 100}]]
                        mmsg [list\
                            "[b]$fighter1[/b] ($fighter1Votes/$fighter1Percentage) vs.\
                            [b]$fighter2[/b] ($fighter2Votes/$fighter2Percentage)"\
                            "$totalVotes vote[s $totalVotes] locked in. Results after fight is over."] $eventName
                    } else {
                        mmsg [list "Time's up! No one voted on [b]$fighter1[/b] vs. [b]$fighter2[/b]."] $eventName
                    }
                }
            }
        }
        array unset poll current
    }
}

proc runAnnouncement {seconds} {
    variable ns
    variable poll
    variable pollTimer
    variable pollInterval
    catch {killutimer $pollTimer}

    if {[info exists poll(current)]} {
        set key $poll(current)
        set fighter1 $poll($key,fighter1)
        set fighter2 $poll($key,fighter2)
        set eventName $poll($key,eventName)

        if {$seconds > 0} {
            set option1 $fighter1
            set option2 $fighter2

            if {[regexp -nocase {\m(?:ufc|bellator|rizin|pfl|invicta|ksw|combate|acb|ultimate fighter|tuf)\M} $eventName]} {
                array set record {}
                foreach fighter [list $fighter1 $fighter2] {
                    set data [sherdog::cache data [sherdog::cache link $fighter]]
                    set record($fighter) [sherdog::graphicalRecord $data 10]
                }
                set fighters [tabulate [list\
                    "$fighter1 | $record($fighter1)"\
                    "$fighter2 | $record($fighter2)"\
                ]]
                set option1 [string trimright [string map {{ | } { }} [lindex $fighters 0]]]
                set option2 [string trimright [string map {{ | } { }} [lindex $fighters 1]]]
            }

            mmsg [list\
                "[b]$fighter1[/b] vs. [b]$fighter2[/b]"\
                "!1 -> $option1"\
                "!2 -> $option2"\
                "Voting !1~ or !2~ will not affect your stats."\
            ] $eventName
            set pollTimer [utimer $pollInterval [list ${ns}::runAnnouncement [expr {$seconds - $pollInterval}]]]
        } else {
            endPoll
        }
    }
}

proc startPoll {unick host handle dest index} {
    if {![onPollChan $unick]} { return 0 }

    variable poll
    variable pollDuration
    variable defaultColSizes

    if {![string is digit -strict $index]} {
        send $unick $dest "Usage: .poll <fight-index>"
    } elseif {[getEvent $unick $host $dest event] && [getFight $unick $host $dest fight $index]} {
        endPoll
        set eventId $event(id)
        set fightId $fight(id)
        set key "$eventId,$fightId"
        set poll($key,fightId) $fightId
        set poll($key,fighter1) $fight(fighter1)
        set poll($key,fighter2) $fight(fighter2)
        set poll($key,eventName) $event(name)
        if {[info exists poll($eventId,lastpoll)] && $poll($eventId,lastpoll) != $key} {
            array unset poll "$poll($eventId,lastpoll),*"
        }
        set poll($eventId,lastpoll) $key
        set poll(current) $key
        db eval {
            UPDATE fights SET result = NULL, notes = NULL, start_time = DATETIME(),
                locked = 0 WHERE id = :fight(id)
        }
        togglePoll "on"

        # cache sherdog information for both fighters
        foreach fighter {fighter1 fighter2} {
            sherdog::query $fight($fighter) results err
        }

        runAnnouncement [expr {$pollDuration * 60}]
    }
    return 1
}
mbind {msg pub} $adminFlag {.poll} ${ns}::startPoll

proc stopPoll {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    endPoll
    return 1
}
mbind {msg pub} $adminFlag {.stop} ${ns}::stopPoll

proc setResult {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    if {![regexp -nocase {^\s*(\d+)\s+(1|2|a|b|draw|nc|nd)\s*(?:[\s,;]+(.+?)\s*)?$} $text m index result notes]} {
        send $unick $dest {Usage: .setresult <index> <1|2|draw|nc|nd> [notes]}
    } elseif {[getFight $unick $host $dest fight $index]} {
        switch [string tolower $result] {
            1 - a {set dbResult $fight(fighter1)}
            2 - b {set dbResult $fight(fighter2)}
            draw {set dbResult "#DRAW"}
            nc {set dbResult "#NC"}
            nd {set dbResult "#ND"}
        }
        if {[db eval {UPDATE fights SET result = :dbResult, notes = :notes, locked = 1 WHERE id = :fight(id)}]} {
            listFights $unick $host $handle $dest
        } else {
            send $unick $dest "Failed to set result for [b]$fight(fighter1) vs. $fight(fighter2)[/b]\
                -- it may have been deleted."
        }
    }
    return 1
}
mbind {msg pub} $adminFlag .setresult ${ns}::setResult

proc announceResult {unick host handle dest result} {
    if {![onPollChan $unick]} { return 0 }

    variable poll
    variable chanFlag
    variable minBestPicks

    if {[getEvent $unick $host $dest event]} {
        set eventId $event(id)
        if {![info exists poll($eventId,lastpoll)]} {
            send $unick $dest "You have to announce the fight before announcing the result."
        } elseif {![regexp -nocase {^\s*(1|2|a|b|draw|nc|nd)\s*(?:[\s,;]+(.+?)\s*)?$} $result m result notes]} {
            send $unick $dest {Usage: .sayresult <1|2|draw|nc|nd> [notes]}
        } else {
            endPoll

            set dbResult ""
            set key $poll($eventId,lastpoll)
            set fightId $poll($key,fightId)
            set fighter1 $poll($key,fighter1)
            set fighter2 $poll($key,fighter2)
            set eventName $poll($key,eventName)

            switch [string tolower $result] {
                1 - a {
                    set dbResult $fighter1
                    set winner $fighter1
                    set loser $fighter2
                }
                2 - b {
                    set dbResult $fighter2
                    set winner $fighter2
                    set loser $fighter1
                }
                draw {
                    set dbResult "#DRAW"
                    set noWinner "DRAW"
                }
                nc {
                    set dbResult "#NC"
                    set noWinner "NO CONTEST"
                }
                nd {
                    set dbResult "#ND"
                    set noWinner "NO DECISION"
                }
            }

            db eval {
                SELECT GROUP_CONCAT(nick) AS nicks,
                    (SELECT MAX(best_streak) FROM users WHERE best_streak > 1) AS best
                    FROM users WHERE best_streak = best
            } oldStreaks {}

            updateRankings
            set oldRankLeaders [db eval {SELECT nick FROM rankings WHERE rank = 1}]

            db eval {UPDATE fights SET result = :dbResult, notes = :notes, locked = 1 WHERE id = :fightId}

            updateRankings

            set winners {}
            set losers {}
            set totalVotes 0

            db eval {
                SELECT nick, wins, losses, streak, rating, rank, result AS pickResult
                    FROM rankings INNER JOIN picks ON picks.user_id = rankings.user_id
                    WHERE fight_id = :fightId;
            } {
                incr totalVotes
                if {$rank == 1 && [lsearch -exact -nocase $oldRankLeaders $nick] == -1} {
                    lappend newRankLeaders $nick
                }
                set stats [format "%s (#%d)" $nick $rank]
                if {$pickResult == 1} {
                    lappend winners $stats
                } elseif {$pickResult == 0} {
                    lappend losers $stats
                }
            }
            if {[info exists noWinner]} {
                set resultText "The fight was declared a [b]$noWinner[/b]."
            } else {
                set resultText "[b]$winner[/b] has defeated $loser!"
            }
            if {$notes ne ""} {
                append resultText " \[ $notes \]"
            }
            if {$totalVotes} {
                set totalWinners [llength $winners]
                set totalLosers [llength $losers]

                if {$totalWinners} {
                    set winners [join [lsort -dictionary $winners] ", "]
                } else {
                    set winners "no winners"
                }
                if {$totalLosers} {
                    set losers [join [lsort -dictionary $losers] ", "]
                } else {
                    set losers "no losers"
                }
                set messages [list\
                    $resultText\
                    [format "Winner%s (%.0f%%): %s"\
                        [s $totalWinners] [expr {($totalWinners / double($totalVotes)) * 100}] $winners]\
                    [format "Loser%s (%.0f%%): %s"\
                        [s $totalLosers] [expr {($totalLosers / double($totalVotes)) * 100}] $losers]\
                    [format "%d vote%s total." $totalVotes [s $totalVotes]]\
                ]

                db eval {
                    SELECT GROUP_CONCAT(nick) AS nicks,
                        (SELECT MAX(best_streak) FROM users WHERE best_streak > 1) AS best
                        FROM users WHERE best_streak = best
                } newStreaks {}

                if {[info exists oldStreaks(best)] && [info exists newStreaks(best)]\
                        && $newStreaks(best) > $oldStreaks(best)} {
                    set oldStreakNicks [lsort -dictionary [split $oldStreaks(nicks) ","]]
                    set newStreakNicks [lsort -dictionary [split $newStreaks(nicks) ","]]
                    set congrats "[b]\[NEW RECORD\][/b] Congratulations,\
                        [b][join $newStreakNicks "[/b], [b]"][/b]!\
                        You have broken the \"HIGHEST WIN STREAK\" record with\
                        [b]$newStreaks(best) wins[/b] in a row!"

                    foreach nick $oldStreakNicks {
                        if {[lsearch -exact -nocase $newStreakNicks $nick] == -1} {
                            lappend oldStreakLeaders $nick
                        }
                    }
                    if {[info exist oldStreakLeaders]} {
                        append congrats " The previous record was held by [join $oldStreakLeaders ", "]\
                            with $oldStreaks(best) straight wins."
                    }
                    append congrats " Type [b].topstreaks[/b] for the best win streakers of all time."
                    lappend messages $congrats
                }
                if {[info exists newRankLeaders]} {
                    lappend messages "[b]\[NEW LEADER\][/b] Congratulations,\
                        [b][join [lsort -dictionary $newRankLeaders] "[/b], [b]"][/b]!\
                        You are now [b]#1[/b] at the top of the leaderboard rankings!\
                        Type [b].rankings[/b] to see the current standings."
                }

                if {[isMainEvent $eventId $fightId $eventName $fighter1 $fighter2]} {
                    lappend messages "[b]\[EVENT HAS ENDED\][/b]: $eventName"

                    set bestPickers [getWinningPickers $eventId]
                    set bestNicks [lindex $bestPickers 0]
                    set bestWins [lindex $bestPickers 1]
                    set bestLosses [lindex $bestPickers 2]

                    if {[expr {$bestWins + $bestLosses}] >= $minBestPicks && $bestWins > 0} {
                        lappend messages "[b]\[BEST FIGHT PICKS\][/b] Congratulations to [b][join $bestNicks "[/b], [b]"][/b].\
                            With a pick record of $bestWins-$bestLosses,\
                            you are the [u]best fight picker[s [llength $bestNicks]][/u] for $eventName!\
                            Step forward and be recognized."

                        foreach nick $bestNicks {
                            foreach chan [channels] {
                                if {[channel get $chan $chanFlag]} {
                                    putserv "MODE $chan +v $nick"
                                }
                            }
                        }
                    }
                }

                mmsg $messages $eventName
            } else {
                mmsg [list $resultText "No one made any picks for this fight!"] $eventName
            }
            listFights $unick $host $handle $dest
        }
    }
    return 1
}
mbind {msg pub} $adminFlag {.sayresult .saywinner} ${ns}::announceResult

proc announceOther {result unick host handle dest notes} {
    if {![onPollChan $unick]} { return 0 }

    if {$notes ne ""} {
        append result "; $notes"
    }
    return [announceResult $unick $host $handle $dest "$result"]
}
mbind {msg pub} $adminFlag {.saydraw} [list ${ns}::announceOther "draw"]
mbind {msg pub} $adminFlag {.saync} [list ${ns}::announceOther "nc"]
mbind {msg pub} $adminFlag {.saynd} [list ${ns}::announceOther "nd"]

proc allowPick {unick dest eventName eventDate} {
    variable minPickDateDiff
    set eventTime [clock scan $eventDate -base [unixtime] -gmt 1]
    if {[expr {($eventTime - [unixtime]) / (60 * 60)}] < $minPickDateDiff} {
        send $unick $dest "Sorry, you can only change your picks up to [u]$minPickDateDiff\
            hour[s $minPickDateDiff][/u] before the event starts. After that, you can only make\
            picks in the channel during the live fight announcements."
        send $unick $dest "[b]$eventName[/b] was scheduled to be held on\
            [formatWordDateTime $eventDate] [timezone] ([timeDiff $eventDate "from now"])."
        return 0
    }
    return 1
}

proc pick {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    if {[getEvent $unick $host $dest event] && [allowPick $unick $dest $event(name) $event(date)]} {
        regsub -all {[\s,;:|]+} [string tolower $text] "" picks
        if {[regexp {^(?:\d+[ab]~?)+$} $picks]} {
            set userId [db onecolumn {SELECT id FROM users WHERE nick = :unick}]
            if {$userId eq ""} {
                if {[db eval {INSERT OR IGNORE INTO users (nick, host) VALUES(:unick, :host)}]} {
                    set userId [db last_insert_rowid]
                } else {
                    # internal error
                    return
                }
            }

            set changes 0

            foreach {m index which} [regexp -all -inline {(\d+)([ab]~?)} $picks] {
                if {[getFight $unick $host $dest fight $index]} {
                    if {[db onecolumn {SELECT locked FROM fights WHERE id = :fight(id)}] == 0} {
                        set winner $fight(fighter1)
                        set loser $fight(fighter2)
                        if {[string index $which 0] eq "b"} {
                            set winner $fight(fighter2)
                            set loser $fight(fighter1)
                        }
                        set vote [expr {[string index $which 1] ne "~"}]
                        if {[db eval {
                            INSERT OR REPLACE INTO picks (user_id, fight_id, pick, vote, pick_date)
                                VALUES(:userId, :fight(id), :winner, :vote, DATETIME())}]
                        } {
                            incr changes
                            continue
                        }
                    }
                }
                lappend badPicks $m
            }

            if {$changes} {
                listFights $unick $host $handle $dest
            }

            if {[info exists badPicks]} {
                set totalBadPicks [llength $badPicks]
                send $unick $dest "You made $totalBadPicks pick[s $totalBadPicks] that\
                    could not be submitted \[[b][join $badPicks "[/b], [b]"][/b]\].\
                    The fight is locked or the pick is invalid."
            }
        } else {
            listFights $unick $host $handle $dest "" 1
        }
    }
    return 1
}
mbind {msg pub} - {.pick .vote} ${ns}::pick

proc delPick {unick host handle dest arg} {
    if {![onPollChan $unick]} { return 0 }

    if {[getEvent $unick $host $dest event] && [allowPick $unick $dest $event(name) $event(date)]} {
        if {![regexp -nocase {^\s*(\d+)\s*(?:[ab]~?)?\s*$} $arg m index]} {
            send $unick $dest "Usage: .delpick <index>"
        } elseif {[getFight $unick $host $dest fight $index]} {
            if {[db eval {
                DELETE FROM picks WHERE user_id IN(SELECT id FROM users WHERE nick = :unick)
                    AND fight_id IN(SELECT id FROM fights WHERE fight_id = :fight(id) AND locked = 0)}]
            } {
                listFights $unick $host $handle $dest
            } else {
                send $unick $dest "Your pick for [b]$fight(fighter1) vs. $fight(fighter2)[/b]\
                    cannot be removed. Either you had no pick for this fight or the fight already started."
            }
        }
    }
    return 1
}
mbind {msg pub} - {.delpick .delpicks} ${ns}::delPick

proc findPicks {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    set text [string trim $text]
    if {[regexp {^\s*@\s*(.+?)\s*$} $text m eventRE]} {
        set user $unick
        set fighter1 ""
        set fighter2 ""
        set query $text
    } else {
        set pair [split $text]
        set user [lindex $pair 0]
        set query [string trim [join [lrange $pair 1 end]]]
        if {$user eq "" ||
                ![regexp -nocase {^(?:([^@]+?)\s*(?:(?:\svs?\.?\s|;)\s*([^@]+?)\s*)?)?(?:@\s*(.+?)\s*)?$}\
                $query m fighter1 fighter2 eventRE]} {
            send $unick $dest {Usage: .picks <user> [fighter1RE [vs fighter2RE]][@ eventRE]}
            return 1
        }
    }

    set sql {
        SELECT pick, vote, fighter1, fighter2, pick_result AS result,
            event_id AS eventId, event_name AS eventName,
            event_start_date AS eventDate FROM vw_picks WHERE nick = :user
    }

    set recent ""
    if {$fighter1 eq "" && $fighter2 eq "" && $eventRE eq ""} {
        set recent " recent"
        lappend sql AND event_start_date > (DATETIME(JULIANDAY() - 1))\
            ORDER BY event_start_date DESC, event_name
    } else {
        lappend sql AND ((fighter1 REGEXP :fighter1 AND fighter2 REGEXP :fighter2)\
            OR (fighter1 REGEXP :fighter2 AND fighter2 REGEXP :fighter1))\
            AND event_name REGEXP :eventRE ORDER BY event_start_date, fight_start_time
    }

    set events {}
    set totalPicks 0
    db eval $sql {
        incr totalPicks
        if {$result == 0} {
            set result " (L)"
        } elseif {$result == 1} {
            set result " (W)"
        }
        set index [lsearch -exact $events $eventName]
        if {$index == -1} {
            set index [llength $events]
            lappend events $eventId $eventName $eventDate
        }
        set mark [expr {$vote == 0 ? "~" : ""}]
        if {[string equal -nocase $pick $fighter1]} {
            lappend picks($eventName) "[b]$fighter1[/b] ${mark}over${mark} $fighter2$result"
        } else {
            lappend picks($eventName) "[b]$fighter2[/b] ${mark}over${mark} $fighter1$result"
        }
    }
    if {[info exists picks]} {
        set totalEvents [expr {[llength $events] / 3}]
        set who [expr {[string equal -nocase $user $unick] ? "Your" : "[b]$user's[/b]"}]
        send $unick $dest "$who $totalPicks pick[s $totalPicks] for $totalEvents matching event[s $totalEvents]:"
        set eventCounter 0
        set numFormat [getNumFormat [array size picks]]
        foreach {eventId eventName eventDate} $events {
            incr eventCounter
            set totalEventPicks [llength $picks($eventName)]
            send $unick $dest [format "[b]%s[/b] on %s (%d pick%s):"\
                $eventName [formatWordDate $eventDate] $totalEventPicks [s $totalEventPicks]]
            foreach pick $picks($eventName) {
                send $unick $dest "  - $pick"
            }
        }
        send $unick $dest "End of$recent picks."
    } else {
        set who [expr {[string equal -nocase $user $unick] ? "You have" : "[b]$user[/b] has"}]
        if {$query eq ""} {
            send $unick $dest "$who no$recent picks."
        } else {
            send $unick $dest "$who no$recent picks matching those search criteria: $query"
        }
    }
    return 1
}
mbind {msg pub} - {.picks .findpick .findpicks} ${ns}::findPicks

proc whoPicked {unick host handle dest query} {
    variable poll
    set showUsage 0
    if {![onPollChan $unick]} { return 0 }

    if {[string is integer -strict $query]} {  ;# .whopicked <index>
        if {[getEvent $unick $host $dest event] && [getFight $unick $host $dest fight $query]} {
            whoPicked $unick $host $handle $dest "$fight(fighter1) vs. $fight(fighter2)"
        }
    } elseif {[regexp {^!\d+$} $query]} {
        if {[info exists poll(current)]} {
            set fighter [expr {$query eq "!1" ? "fighter1" : "fighter2"}]
            whoPicked $unick $host $handle $dest $poll($poll(current),$fighter)
        } else {
            set showUsage 1
        }
    } elseif { [info exists poll(current)] && $query eq ""} {
        whoPicked $unick $host $handle $dest "$poll($poll(current),fighter1) vs $poll($poll(current),fighter2)"
    } elseif {![regexp -nocase {^\s*([^@%_]+?)\s*(?:\s(vs?\.?|over)\s+([^@%_]+?)\s*)?(?:@\s*(.+?)\s*)?\s*$}\
                $query m fighter1 searchType fighter2 eventRE]
    } {
        set showUsage 1
    } else {
        set havePicked 0
        set fighter1Glob "$fighter1%"
        set fighter2Glob [expr {$fighter2 eq "" ? "" : "$fighter2%"}]
        set sql {
            SELECT GROUP_CONCAT(nick) AS nicks, pick,
                (CASE WHEN pick = fighter1 THEN fighter2 ELSE fighter1 END) AS opponent,
                event_name AS eventName, event_start_date AS eventDate FROM vw_picks
                WHERE ((fighter1 LIKE :fighter1Glob AND fighter2 REGEXP :fighter2)
                OR (fighter1 LIKE :fighter2Glob AND fighter2 REGEXP :fighter1)
                OR (fighter2 LIKE :fighter1Glob AND fighter1 REGEXP :fighter2)
                OR (fighter2 LIKE :fighter2Glob AND fighter1 REGEXP :fighter1))
        }
        if {[string equal -nocase $searchType "over"] || $searchType eq ""} {
            lappend sql AND pick REGEXP :fighter1
        }
        lappend sql AND event_name REGEXP :eventRE GROUP BY fight_id, pick
        db eval $sql {
            regsub -all {,} $nicks " " picks($eventDate\n$eventName\n$pick\n$opponent)
            append picks($eventDate\n$eventName\n$pick\n$opponent) " "
        }
        if {[info exists poll(current)]} {
            set key $poll(current)
            if {[info exists poll($key,fightId)]} {
                set fighter1 $poll($poll(current),fighter1)
                set fighter2 $poll($poll(current),fighter2)
                set eventName $poll($key,eventName)
                set eventDate [db onecolumn { SELECT start_date FROM events WHERE name = $eventName }]
                if {![info exists picks($eventDate\n$eventName\n$fighter2\n$fighter1)]} { set picks($eventDate\n$eventName\n$fighter2\n$fighter1) ""}
                if {![info exists picks($eventDate\n$eventName\n$fighter1\n$fighter2)]} { set picks($eventDate\n$eventName\n$fighter1\n$fighter2) ""}
                foreach user [array names poll "$key,picks,*"] {
                    set nick [lindex $poll($user) 2]
                    if {[lindex $poll($user) 0] == 1} {
                        set fighter1 $poll($poll(current),fighter1)
                        set fighter2 $poll($poll(current),fighter2)
                    } else {
                        set fighter1 $poll($poll(current),fighter2)
                        set fighter2 $poll($poll(current),fighter1)
                    }
                    regsub "$nick " $picks($eventDate\n$eventName\n$fighter2\n$fighter1) "" picks($eventDate\n$eventName\n$fighter2\n$fighter1)
                    if {[string first  "$nick " $picks($eventDate\n$eventName\n$fighter1\n$fighter2)] == -1} {
                        append picks($eventDate\n$eventName\n$fighter1\n$fighter2) "$nick "
                    }
                }
            }
        }
        if {[info exists picks]} {
            foreach key [lsort -dictionary [array names picks]] {
                foreach {eventDate eventName pick opponent} [split $key \n] {
                    set nicks [split [string trim $picks($key) " "]]
                    set totalUsers [llength [split $nicks]]
                    if {$totalUsers >=1} {
                        set havePicked 1
                        send $unick $dest "$totalUsers user[s $totalUsers]\
                            picked [b]$pick[/b] over [b]$opponent[/b]\
                            at $eventName ([formatWordDate $eventDate 0]):"
                        send $unick $dest "  [join [lsort -dictionary $nicks] ", "]"
                    }
                }
            }
        }
        if {!$havePicked} {
            send $unick $dest "No one picked $query."
        }
    }
    if {$showUsage} {
        send $unick $dest {Usage: .whopicked [<fighter1> [<vs | over> fighter2][@ eventRE] | <!1 | !2>]}
    }
    return 1
}
mbind {msg pub} - {.whopick .whopicked} ${ns}::whoPicked

proc mergeUsers {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    regexp {^\s*(-f(?:orce)?\s+)?(.*?)\s*$} $text m force text
    set nicks [split [string trim $text]]
    if {[llength $nicks] < 2} {
        send $unick $dest {Usage: .merge [-f] <targetNick> <dupeNick1>[ dupeNickN]}
    } else {
        set target [lindex $nicks 0]
        set targetUser [db eval {SELECT id, nick FROM users WHERE nick = :target}]
        if {$targetUser eq ""} {
            send $unick $dest "Target user '[b]$target[/b]' does not exist."
        } else {
            set dupes [lrange $nicks 1 end]
            set totalDupes [llength $dupes]

            if {$force eq ""} {
                set targetNick [lindex $targetUser 1]
                send $unick $dest "This action will merge the stats and picks from\
                    [expr {$totalDupes + 1}] users and permanently [u]remove[/u]\
                    [b][join $dupes "[/b], [b]"][/b] from the database."
                send $unick $dest "Target user's stats:"
                send $unick $dest " * [stats $unick $host $handle $dest $targetNick 1]"
                send $unick $dest "Duplicate user[s $totalDupes]:"
                set i 0
                foreach dupe $dupes {
                    send $unick $dest "[incr i]. [stats $unick $host $handle $dest $dupe 1]"
                }
                send $unick $dest "To proceed, type: [b].merge -f $text[/b]"
            } else {
                set targetId [lindex $targetUser 0]
                set pickMerges [db eval [populate {
                    UPDATE picks SET user_id = :targetId, result = result
                        WHERE user_id IN(SELECT id FROM users WHERE nick IN(::dupes))
                        AND fight_id NOT IN(SELECT fight_id FROM picks WHERE user_id = :targetId)
                }]]
                db eval [populate {
                    SELECT best_streak AS bestStreak, best_streak_date AS bestStreakDate FROM users
                        WHERE nick IN(::nicks) ORDER BY best_streak DESC, best_streak_date LIMIT 1
                }] r {}
                db eval [populate {
                    SELECT worst_streak AS worstStreak, worst_streak_date AS worstStreakDate FROM users
                        WHERE nick IN(::nicks) ORDER BY worst_streak, worst_streak_date LIMIT 1
                }] r {}
                db eval {UPDATE users SET best_streak = :r(bestStreak),
                    best_streak_date = :r(bestStreakDate), worst_streak = :r(worstStreak),
                    worst_streak_date = :r(worstStreakDate) WHERE nick = :target
                }
                db eval [populate {DELETE FROM users WHERE nick IN(::dupes)}]
                send $unick $dest "Merged $totalDupes user[s $totalDupes] with a net total of\
                    $pickMerges pick[s $pickMerges] into user [b]$target[/b]."
            }
        }
    }
    return 1
}
mbind {msg pub} $adminFlag {.merge .mergeusers} ${ns}::mergeUsers

proc updateRankings {} {
#   SELECT GROUP_CONCAT(user_id), ROUND(rating, 4) AS r FROM vw_stats
#       GROUP BY r, streak ORDER BY r DESC, streak DESC;

    return [db eval {
        DROP TABLE IF EXISTS temp_rank;
        CREATE TEMPORARY TABLE temp_rank AS SELECT ROUND(rating, 4) AS r, streak
            FROM vw_stats GROUP BY r, streak ORDER BY r DESC, streak DESC;
        DELETE FROM rankings;
        INSERT INTO rankings SELECT user_id, nick, wins, losses, vw_stats.streak,
            (vw_stats.rating * 10) AS rating, temp_rank.ROWID AS rank FROM vw_stats
            INNER JOIN temp_rank ON temp_rank.r = ROUND(vw_stats.rating, 4)
            AND temp_rank.streak = vw_stats.streak;
    }]
}

proc stats {unick host handle dest user args} {
    if {![onPollChan $unick]} { return 0 }

    if {[set user [string trim $user]] eq ""} {
        set user $unick
    }
    updateRankings
    set msg ""

    db eval {
        SELECT users.nick, users.wins, users.losses, users.streak,
            users.best_streak AS bestStreak, rating, rank
            FROM rankings INNER JOIN users ON user_id = users.id WHERE users.nick = :user;
    } {
        set winPercent [expr {round(($wins / double($wins + $losses)) * 100)}]
        set lossPercent [expr {100 - $winPercent}]
        set msg [format "%s >> rank #%d, rating %.3f, %d win%s (%d%%), %d loss%s (%d%%), streak %+d"\
            $nick $rank $rating $wins [s $wins] $winPercent $losses [s $losses "es"] $lossPercent $streak]
        if {$bestStreak > 0} {
            append msg [format " (%+d personal best)" $bestStreak]
        }
    }
    if {$msg ne ""} {
        if {$args eq {}} {
            set msg "[b]Poll Stats:[/b] $msg"
        }
    } elseif {[string equal -nocase $user $unick]} {
        set msg "You have no pick stats yet."
    } else {
        set msg "[b]$user[/b] has no pick stats yet."
    }
    if {$args == {}} {
        send $unick $dest $msg
        return 1
    }
    return $msg
}
mbind {msg pub} - .stats ${ns}::stats

proc showRankings {unick host handle dest text} {
    if {![onPollChan $unick]} { return 1 }

    getLimits $text trigger offset limit maxRank
    updateRankings

    set sql {SELECT nick, wins, losses, streak, rating, rank FROM rankings}
    if {[string is digit -strict $maxRank]} {
        lappend sql WHERE rank >= :maxRank
    }
    lappend sql ORDER BY rank, nick
    if {$offset >= 0 || $limit >= 0} {
        lappend sql LIMIT :offset, :limit
    }

    set users {}
    db eval $sql {
        lappend users [format "#%d [b]%s[/b] -> R:%.3f W:%d L:%d (%.0f%%) %+d"\
            $rank $nick $rating $wins $losses [expr {($wins / double($wins + $losses)) * 100}] $streak]
    }
    set users [tabulate $users " "]
    set totalResults [llength $users]
    if {$totalResults} {
        send $unick $dest "[b][u]FIGHT PICK RANKINGS[/u][/b]"
        foreach user $users {
            send $unick $dest $user
        }
        if {$totalResults == $limit} {
            send $unick $dest "For the next $limit results, type:\
                [b]$trigger[expr {$offset + $limit}] $maxRank[/b]"
        }
    } elseif {$offset > 0 || $maxRank > 0} {
        send $unick $dest "No more results."
    } else {
        send $unick $dest "There are no fight picks yet."
    }

    return [logStackable $unick $host $handle $dest $text]
}
mbind {msgm pubm} - {"% .rank*" "% .leader*"} ${ns}::showRankings

# user-defined function for SQLite
proc streakSQL {id picks} {
    if {[llength $picks]} {
        set picks [lsort -integer -decreasing -index 0 $picks]
        set lastResult [lindex [lindex $picks 0] 1]
        set i 0
        foreach {timestamp result} [join $picks] {
            if {$result == $lastResult} {
                incr i
            } else {
                break
            }
        }
        return [expr {$lastResult ? $i : -$i}]
    }
    return 0
}

proc showStreaks {unick host handle dest text} {
    if {![onPollChan $unick]} { return 1 }

    getLimits $text trigger offset limit maxStreak
    updateRankings

    set sql {SELECT nick, streak, rank FROM rankings}
    if {[string is digit -strict $maxStreak]} {
        lappend sql WHERE streak <= :maxStreak
    }
    lappend sql ORDER BY streak DESC, rank, nick
    if {$offset >= 0 || $limit >= 0} {
        lappend sql LIMIT :offset, :limit
    }

    set users {}
    db eval $sql {
        lappend users [format "%+d [b]%s[/b] #%d" $streak $nick $rank]
    }
    set users [tabulate $users " "]
    set totalResults [llength $users]
    if {$totalResults} {
        send $unick $dest "[b][u]WIN STREAKS[/u][/b]"
        foreach user $users {
            send $unick $dest $user
        }
        if {$totalResults == $limit} {
            send $unick $dest "For the next $limit results, type:\
                [b]$trigger[expr {$offset + $limit}] $maxStreak[/b]"
        }
    } elseif {$offset > 0 || $maxStreak > 0} {
        send $unick $dest "No more results."
    } else {
        send $unick $dest "No one is on a win streak! You guys suck."
    }

    return [logStackable $unick $host $handle $dest $text]
}
mbind {msgm pubm} - {"% .streak*"} ${ns}::showStreaks

proc bestStreaks {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    set streaks [db eval {
        SELECT GROUP_CONCAT(nick), best_streak, STRFTIME('%m/%d/%Y', MIN(best_streak_date))
            FROM users WHERE best_streak > 1 GROUP BY best_streak
            ORDER BY best_streak DESC LIMIT 5
    }]
    set totalRecords [expr {[llength $streaks] / 3}]
    if {$totalRecords} {
        send $unick $dest "[b][u]TOP 5 WIN STREAKERS OF ALL TIME[/u][/b]"
        set winsFormat "%[string length [lindex $streaks 1]]d"
        set i 0
        foreach {nicks bestStreak date} $streaks {
            set nickFormat [expr {$i ? "%s" : "[b]%s[/b]"}]
            send $unick $dest [format "[b]#%d[/b] | $winsFormat straight wins | %s | $nickFormat"\
                [incr i] $bestStreak $date [join [lsort -dictionary [split $nicks ,]]]]
        }
    } else {
        send $unick $dest "No win streaks yet."
    }
    return 1
}
mbind {msg pub} - {.beststreaks .top .topstreak .topstreaks} ${ns}::bestStreaks

proc worstStreaks {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    set streaks [db eval {
        SELECT GROUP_CONCAT(nick), ABS(worst_streak), STRFTIME('%m/%d/%Y', MIN(worst_streak_date))
            FROM users WHERE worst_streak < -1 GROUP BY worst_streak
            ORDER BY worst_streak LIMIT 5
    }]
    set totalRecords [expr {[llength $streaks] / 3}]
    if {$totalRecords} {
        send $unick $dest "[b][u]THE 5 WORST STREAKERS OF ALL TIME[/u][/b]"
        set lossesFormat "%[string length [lindex $streaks 1]]d"
        set i 0
        foreach {nicks worstStreak date} $streaks {
            set nickFormat [expr {$i ? "%s" : "[b]%s[/b]"}]
            send $unick $dest [format "[b]#%d[/b] | $lossesFormat straight losses | %s | $nickFormat"\
                [incr i] $worstStreak $date [join [lsort -dictionary [split $nicks ,]]]]
        }
    } else {
        send $unick $dest "No losing streaks yet."
    }
    return 1
}
mbind {msg pub} - {
    .worst .worststreak .worststreaks .bottom .bottomstreak .bottomstreaks
} ${ns}::worstStreaks

proc searchSherdog {unick host handle dest text} {
    variable poll
    variable maxPublicLines
    variable defaultColSizes

    if {![onPollChan $unick]} { return 1 }

    logStackable $unick $host $handle $dest $text

    set cmd [lindex [split $text] 0]
    set query [string trim [join [lrange [split $text] 1 end]]]
    regexp {^\S+?(\d*|\*),?([*\d,]+)?$} $cmd m limit columns

    set columns [split $columns ,]
    if {[llength $columns] == 0 && [string index $cmd end] ne ","} {
        set columns $defaultColSizes
    }

    set target $unick
    set queryOptions [list -v $columns]
    if {[string is digit -strict $limit]} {
        set queryOptions [list -s $limit $columns]
        set target $dest
    }

    set queries {}

    switch -nocase -regexp -matchvar match -- $query {
        {^$} {
            if {[info exists poll(current)]} {
                lappend queries $poll($poll(current),fighter1) $poll($poll(current),fighter2)
            }
        }
        {^!([12])~?$} {
            if {[info exists poll(current)]} {
                lappend queries $poll($poll(current),fighter[lindex $match 1])
            }
        }
        {^\d+$} {
            if {[getEvent $unick $host $dest event] && [getFight $unick $host $dest fight $match]} {
                lappend queries $fight(fighter1) $fight(fighter2)
            }
        }
        {^(\d+)([ab])$} {
            set fightIndex [lindex $match 1]
            if {[getEvent $unick $host $dest event] && [getFight $unick $host $dest fight $fightIndex]} {
                set fighterId [string tolower [lindex $match 2]]
                lappend queries $fight(fighter[expr {$fighterId eq "a" ? 1 : 2}])
            }
        }
        default {
            lappend queries $query
        }
    }

    if {[llength $queries]} {
        foreach q $queries {
            if {[sherdog::query $q results err {*}$queryOptions]} {
                if {[llength $results] > $maxPublicLines} {
                    set target $unick
                }
                msend $target $dest $results
            } else {
                send $unick $dest $err
            }
        }
    } else {
        send $unick $dest {No poll is currently running. Usage: .sherdog <fighter> or .sherdog <index>[a|b]}
    }

    return 1
}
mbind {msgm pubm} - {"% .sh*"} ${ns}::searchSherdog
bind time - "30 * * * *" ::sherdog::pruneCache

proc getBestPickers {eventId} {
    set rows [db eval { SELECT nick, pick_result, event_name FROM vw_picks \
        WHERE pick_result IS NOT NULL AND event_id = :eventId AND vote IS NOT 0 ORDER BY user_id}]
    if {$rows <= 0} {
        return {}
    }
    set pickList {}
    foreach {nick result event_name} $rows {
        set pick {}
        set nickIndex [lsearch -index 0 $pickList $nick]
        if {$nickIndex < 0} {
            set nickIndex [llength $pickList]
            lappend pick $nick 0 0
            lappend pickList $pick
        }
        set index [expr {$result == 1 ? 1 : 2}]
        set value [lindex $pickList $nickIndex $index]
        incr value
        lset pickList $nickIndex $index $value
    }
    return [lsort -integer -index 1 -decreasing [lsort -integer -index 2 -decreasing $pickList]]
}

proc getWinningPickers {eventId} {
    set winners {}
    set pickers [getBestPickers $eventId]
    set bestWins [lindex [lindex $pickers 0] 1]
    set bestLosses [lindex [lindex $pickers 0] 2]
    foreach picker $pickers {
        if {[lindex $picker 1] == $bestWins && [lindex $picker 2] == $bestLosses} {
            lappend winners [lindex $picker 0]
            continue
        }
        break
    }
    return [list $winners $bestWins $bestLosses]
}

proc getMainEvent {eventId} {
  return [db onecolumn {SELECT main_event FROM events WHERE id = :eventId}]
}

proc isMainEvent {eventId fightId eventName fighter1 fighter2} {
    set mainEvent [getMainEvent $eventId]
    if {$mainEvent ne ""} {
        return [expr {$mainEvent == $fightId}]
    }
    if {![regexp {(\S+)\s+vs\.?\s+(\S+)} $eventName m mainFighter1 mainFighter2]} {
        return 0
    }
    return [expr {([lsearch -nocase -exact $fighter1 $mainFighter1] >= 0 && [lsearch -nocase -exact $fighter2 $mainFighter2] >= 0)
               || ([lsearch -nocase -exact $fighter1 $mainFighter2] >= 0 && [lsearch -nocase -exact $fighter2 $mainFighter1] >= 0)}]
}

proc best {unick host handle dest text} {
    if {![onPollChan $unick]} { return 1 }

    getLimits $text trigger offset limit expr
    set evid ""
    set event_name ""

    if {$expr eq ""} {
        if {[getEvent $unick $host $dest event]} {
            set evid $event(id)
            set event_name $event(name)
        } else {
            set showUsage 1
        }
    } else {
        set eventName [string trim $expr {\ @}]
        set currentTime [now]
        set rows [db eval {SELECT id, name FROM events \
            WHERE name REGEXP :eventName AND start_date <= $currentTime ORDER BY start_date ASC}]
        set numEvents [expr {[llength $rows] / 2}]
        if {$numEvents >= 2} {
            send $unick $dest "Multiple events found. Showing the results of the latest matching event..."
        } elseif {$numEvents <= 0} {
            send $unick $dest "Event '$eventName' not found."
            return 1
        }
        set evid [lindex $rows [expr {[llength $rows] - 2}]]
        set event_name [lindex $rows [expr {[llength $rows] - 1}]]
    }
    if {[info exist showUsage]} {
        send $unick $dest "Usage: .best <eventRE>"
        return 1
    }

    set pickList [getBestPickers $evid]
    if {[llength $pickList] == 0} {
        send $unick $dest "Nobody has picked for this event, or the results haven't been published yet."
        return 1
    }

    send $unick $dest "[b][u]TOP PICKERS @ $event_name[/u][/b]"
    send $unick $dest "[b]RANK  NICK        WINS  LOSSES[/b]"
    set oldWins 0
    set oldLosses 0
    set oldRank 0
    set userRank 0
    set reachedLimit 0
    foreach pick $pickList {
        incr counter
        set rank $counter
        foreach {nick wins losses} $pick {
            if {$wins == $oldWins && $losses == $oldLosses} {
                set rank $oldRank
            } else {
                set oldWins $wins
                set oldLosses $losses
                set oldRank $rank
            }
            if {$nick == $unick} { set userRank $rank }
            if {$counter>$offset} {
                send $unick $dest [format "#%-4d %-12s %-6d %-6d" $rank $nick $wins $losses]
            }
        }
        if {$counter == [expr {$limit + $offset}]} {
            set reachedLimit 1
            break
        }
    }
    if {$userRank} {
        send $unick $dest "You are ranked $userRank out of [llength $pickList]"
    }
    if {$reachedLimit} {
        set limit2 ""
        if {$limit != 20} {
            set limit2 ",$limit"
        }
        send $unick $dest "For the next $limit results, type: [b]$trigger[expr {$offset + $limit}]$limit2 $expr[/b]"
    }

    return [logStackable $unick $host $handle $dest $text]
}
mbind {msgm pubm} - {"% .best*"} ${ns}::best

proc help {unick host handle dest text} {
    if {![onPollChan $unick]} { return 0 }

    variable adminFlag
    variable scriptVersion

    send $unick $dest "[b][u]FIGHT BOT $scriptVersion HELP[/u][/b]"

    foreach {access line} [concat {
        @ {.import ................................................. Import fights and betting lines from the web}
        - {.events ................................................. Show all upcoming fight events}
        - {.event <index> .......................................... Select event as command context}
        @ {.addevent <eventName>[; yyyy-MM-dd HH:mm Z] ............. Add fight event to be held on specified date}
        @ {.delevent <index> ....................................... Delete fight event at specified index}
        @ {.renameevent <index> <newEventName> ..................... Rename event at specified index}
        @ {.mergeevents <oldEventIndex> <newEventIndex> ............ Merge events (new event is deleted; old one is renamed)}
        @ {.setmainevent <index> ................................... Set fight index as the main event}
        @ {.unsetmainevent ......................................... Unset main event}
        @ {.endevent ............................................... Remove event from upcoming events list}
        - {.findevent[offset[,limit]] <eventRE> .................... Find an event matching the given regex}
        - {.notes [id] ............................................. Show notes for selected or specified event}
        @ {.setnotes <text> ........................................ Set notes for selected event}
        @ {.clearnotes ............................................. Clear notes from selected event}
        @ {.sayevent ............................................... Announce selected event}
        - {.fights [user] .......................................... List fights for selected event with picks from user}
        @ {.addfight f1 [<+-odds1>] vs f2 [<+-odds2>] .............. Add fight to selected event}
        @ {.delfight <index> ....................................... Delete fight at index from selected event}
        @ {.renamefighter <index><a|b> <newFighterName> ............ Rename specified fighter}
        @ {.lock <index> ........................................... Lock fight at index to disallow .pick on it}
        @ {.unlock <index> ......................................... Unlock fight at index to allow .pick on it}
        - {.findfight [f1RE [vs f2RE]][@ eventRE] .................. Show info for matching fights}
        @ {.poll <index> ........................................... Start polling for selected fight index}
        @ {.stop ................................................... Stop polling}
        @ {.setresult <index> <1|2|draw|nc|nd> [notes] ............. Set result of fight at index}
        @ {.sayresult <1|2|draw|nc|nd> [notes] ..................... Announce result of last announced fight}
        @ {.saydraw [notes] ........................................ Alias for .sayresult draw}
        @ {.saync [notes] .......................................... Alias for .sayresult nc}
        @ {.saynd [notes] .......................................... Alias for .sayresult nd}
        - {.whopicked [<f1> [<vs|over> f2][@ eventRE] | <!1|!2>] ... Show who picked a particular fighter}
        - {.picks <user> [f1RE [vs f2RE]][@ eventRE] ............... Show user picks for matching events/fights}
        - {.pick <index><a|b>[~][ <indexN><a|b>[~]] ................ Pick fighter at index to win from selected event}
        - {.delpick <index> ........................................ Delete pick for selected event}
        @ {.merge <targetNick> <nick1>[ nickN] ..................... Delete nick(s) and merge their picks/stats into target}
        - {.stats [user] ........................................... Show stats for specified user}
        - {.rankings[offset[,limit]] [maxRank] ..................... Show fight pick rankings}
        - {.streaks[offset[,limit]] [maxStreak] .................... Show current win streak rankings}
        - {.topstreaks ............................................. Show top 5 win streakers of all time}
        - {.worststreaks ........................................... Show the 5 worst streakers of all time}
        - {.sherdog [fighter|index[a|b]|!1|!2] ..................... Display Sherdog Fight Finder records}
        - {.best[offset[,limit]] [eventRE] ......................... Show the 20 top pickers for matching/selected event}
        - {.help ................................................... Display this help information}
        - { }} [list\
        - "NOTES: \"RE\" suffix indicates a regular expression. All times are [timezone]."] {
        - { }
    }] {
        if {$access eq "-" || [matchchanattr $handle $adminFlag $dest]} {
            send $unick $dest $line
        }
    }

    send $unick $dest "End of help."
    return 1
}
mbind {msg pub} - {.help} ${ns}::help

if {[catch {init} error]} {
    die $error
}
registerCleanup ${ns} ${ns}::db


putlog "[b]Fight Bot TCL $scriptVersion by makk loaded![/b]"

}
