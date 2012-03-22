####################################################################
#
# File: fights.tcl
#
# Description:
#   MMA/Boxing fight logger and polling script for Eggdrop bots.
#
# Author: makk@EFnet
#
# Release Date: May 14, 2010
#  Last Update: Mar 21, 2012
#
# Requirements: Eggdrop 1.6.16+, TCL 8.5+, SQLite 3.6.19+
#
####################################################################

source "[file dirname [info script]]/util.tcl"

package require util
package require http

namespace eval ::fights {

namespace import ::util::*

variable botTitle      "[b][u]FIGHT POLL[/u][/b]"

variable database        "fights.db"   ;# database file
variable sqlScript       "fights.sql"  ;# SQL script file to create database
variable chanFlag        "fights"      ;# channel flag to enable polling
variable adminFlag       "P|P"         ;# user flag for allowing poll administration
variable minPickDateDiff 2             ;# allow picks up to this many hours before event starts
variable pollDuration    15            ;# max minutes before polling automatically ends
variable pollInterval    120           ;# send reminders every this many seconds during polling
variable maxResults      20            ;# max command results to show at one time
variable backupTime      "02:22"       ;# military time of day to perform daily backup
variable updateTime      "03:33"       ;# military time of day to update upcoming events from web
variable putCommand      putnow        ;# send function: putnow, putquick, putserv, puthelp
variable debugLogLevel   8             ;# log all output to this log level [1-8, 0 = disabled]


variable scriptVersion "1.4.6"
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
	variable debugLogLevel

	endPoll

	unset -nocomplain poll users

	if {[info commands ${ns}::db] == ""} {
		if {[catch {loadDatabase ${ns}::db $database [list $sqlScript]} error]} {
			return -code error $error
		}
		catch {db function STREAK ${ns}::streakSQL}

		if {[catch {db eval {SELECT * FROM vw_stats LIMIT 1}} error]} {
			return -code error "*** Database integrity test failed: $error"
		}
		bindSQL "sqlfights" ${ns}::db
		scheduleBackup ${ns}::db $database $backupTime $debugLogLevel
	}
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

proc send {unick dest text} {
	variable putCommand
	variable debugLogLevel
	if {$dest != ""} {
		if {$unick == $dest} {
			set put putMessage
		} else {
			set put putNotice
		}
		return [$put $unick $dest $text $putCommand $debugLogLevel]
	}
	return
}

proc msg {target text} {
	variable putCommand
	variable debugLogLevel
	return [putMessage $target $target $text $putCommand $debugLogLevel]
}

proc mmsg {messages {title ""}} {
	variable chanFlag
	variable botTitle
	set title [expr {$title == "" ? $botTitle : "$botTitle :: $title"}]
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

proc importFights {unick host handle dest text} {
	if {![onPollChan $unick]} { return 0 }

	variable ns
	variable imports

	set url "http://www.bestfightodds.com/"
	send $unick $dest "Importing fights from $url.  Please wait..."

	array unset imports
	if {[catch {parseHTML [http::data [geturlex $url]] ${ns}::parseBestFightOdds} error]} {
		send $unick $dest "Error importing fights: $error"
		return 1
	}

	set totalEvents 0
	set totalFights 0

	foreach key [array names imports "event,*"] {
		incr totalEvents
		set eventName [string range $key 6 end]
		set eventDate [lindex $imports($key) 0]
		if {[db eval {INSERT OR IGNORE INTO events (name, start_date) VALUES(:eventName, :eventDate)}]} {
			set eventId [db last_insert_rowid]
		} else {
			db eval {UPDATE events SET name = :eventName WHERE name = :eventName}
			set eventId [db onecolumn {SELECT id FROM events WHERE name = :eventName}]
		}
		foreach {fighter1 odds1 fighter2 odds2} [lrange $imports($key) 1 end] {
			if {$fighter1 != "" && $fighter2 != ""} {
				incr totalFights
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

	if {$dest != ""} {
		listEvents $unick $host $handle $dest ""
	}

	array unset imports
	send $unick $dest "Successfully imported $totalEvents event[s $totalEvents]\
		and $totalFights fight[s $totalFights]."
	return 1
}
mbind {msg pub} $adminFlag {.importfights .importevents .updatefights} ${ns}::importFights

proc parseBestFightOdds {tagtype state props body} {
	variable imports

	set tag "$state$tagtype"

	if {$tag == "hmstart"} {
		set imports(event) ""
		set imports(state) ""
	} elseif {$tag == "div"} {
		if {$props == {class="table-header"}} {
			set imports(state) "event"
		}
	} elseif {$tag == "/hmstart"} {
		set imports(state) ""
		array unset imports event
		return
	}

	switch $imports(state) {
		event {
			if {$tag == "a" } {
				set imports(event) "event,$body"
				set imports($imports(event)) {}
				set imports(state) "date"
			}
		}
		date {
			if {$tag == "/a"} {
				regsub -all {^[-\s]+|(?:st|nd|rd|th)$} $body "" date
				if {[set date [string trim $date]] == ""} {
					set date [clock format [clock scan "6 months" -base [unixtime] -timezone [tz]] -format "%Y-%m-%d 00:00:00" -gmt 1]
				} else {
					if {[string length $date] < 7} {
						set tz ":America/New_York"
						if {[catch {clock scan 0 -timezone $tz}]} {
							set tz "-0500"  ;# default to EST
						}
						# if assuming current year puts the date more than 1 week before now, assume next year
						if {[expr [clock scan $date -base [unixtime] -timezone $tz] - [unixtime]] < -[expr 7 * 24 * 60 * 60]} {
							append date [clock format [clock scan "1 year" -base [unixtime] -timezone $tz] -format ", %Y" -gmt 1]
						}

						switch -glob -nocase -- [string range $imports(event) 6 end] {
							UFC* {append date " 9:00pm"}
							Strikeforce* {append date " 10:00pm"}
							Bellator* {append date " 8:00pm"}
							DREAM* - K1* - "K-1*" - Sengoku* {append date " 3:00am"}
							default {append date " 6:00pm"}
						}
						catch {set date [clock format [clock scan $date -timezone $tz]\
							-format "%Y-%m-%d %H:%M:%S" -timezone [tz]]}
					}
					if {[catch {set date [toGMT $date]}]} {
						set date [now]
					}
				}
				lappend imports($imports(event)) $date
				set imports(state) "fightercell"
			}
		}
		fightercell {
			if {$tag == "th" && $props == {scope="row"}} {
				set imports(state) "fighter"
			}
		}
		fighter {
			if {$tag == "a"} {
				lappend imports($imports(event)) [htmlDecode $body]
				set imports(state) "odds"
			}
		}
		odds {
			if {$tag == "span" && [string match {*class="bestbet"*} $props]} {
				set odds [expr {[string is integer $body] ? $body : 0}]
				lappend imports($imports(event)) $odds
				set imports(state) "fightercell"
			}
		}
	}
}

proc updateEvents {minute hour day month year} {
	importFights "" "" "" "" ""
}
bind time - "[lindex [split $updateTime :] 1] [lindex [split $updateTime :] 0] * * *" ${ns}::updateEvents

proc setTimeZone {unick host handle dest timezone} {
	if {![onPollChan $unick]} { return 0 }

	set tz [string trim $timezone]
	if {$tz == ""} {
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
mbind {msg pub} - {.tz .timezone .settz .settimezone} ${ns}::setTimeZone

proc getLimits {text outTrigger outOffset outLimit outArgs} {
	variable maxResults

	upvar $outTrigger trigger
	upvar $outOffset offset
	upvar $outLimit limit
	upvar $outArgs args

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

	clearEvents $unick $host

	getLimits $text trigger offset limit expr

	set query {SELECT id, name, start_date FROM events}
	if {$expr == ""} {
		lappend query WHERE locked = 0 AND start_date > (DATETIME(JULIANDAY() - 1)) ORDER BY start_date, name
	} else {
		lappend query WHERE name REGEXP :expr ORDER BY start_date, name
	}
	lappend query LIMIT :offset, :limit

	set events [db eval $query]

	set totalEvents [expr [llength $events] / 3]
	if {$totalEvents} {
		set tzNotice "\[ all times are [timezone 1] \]"
		if {$expr == ""} {
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
			if {$eventName != "Future Events" && $eventDate != ""} {
				append eventItem " - [formatWordDateTime $eventDate 0] ([timeDiff $eventDate])"
			}
			send $unick $dest $eventItem
		}
		if {$totalEvents == $limit} {
			send $unick $dest "For the next $limit results, type: [b]$trigger[expr $offset + $limit] $expr[/b]"
		}
		if {$expr == ""} {
			send $unick $dest "To search for an event, type: [b].findevent <eventRE>[/b]"
		}
		send $unick $dest "To select an event, type: [b].event <index>[/b]"
	} elseif {$offset > 0} {
		send $unick $dest "No more events."
	} else {
		send $unick $dest "No events found."
	}
	if {$text == ""} {
		return 1
	}
	return [logStackable $unick $host $handle $dest $text]
}
mbind {msgm pubm} - {"% .listevents*" "% .findevent*"} ${ns}::listEvents

proc event {unick host handle dest index} {
	if {![onPollChan $unick]} { return 0 }

	if {[selectEvent $unick $host "" $index]} {
		listFights $unick $host $handle $dest
	} else {
		listEvents $unick $host $handle $dest ""
		if {$index != ""} {
			send $unick $dest " "
			send $unick $dest "The upcoming events list was reloaded.\
				Verify your selection above and try again."
		}
	}
	return 1
}
mbind {msg pub} - {.event .events .selevent .selectevent .select} ${ns}::event

proc addEvent {unick host handle dest text} {
	if {![onPollChan $unick]} { return 0 }

	if {![regexp {^\s*([^;]+?)\s*(?:;\s*(.+?)\s*)?$} $text m eventName eventDate]} {
		send $unick $dest {Usage: .addevent <event>[; yyyy-MM-dd HH:mm Z]}
	} else {
		set defaultDate 0
		regsub -all -nocase {\s*@\s*|\s+at\s+} $eventDate " " eventDate
		if {$eventDate == "" || [catch {set eventDate [toGMT $eventDate]}]} {
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
					scheduled for today by default.  This means users are not allowed to [b].pick[/b]\
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
		if {$force == ""} {
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
	if {![string is digit -strict $index] || $eventName == ""} {
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
mbind {msg pub} $adminFlag {.renameevent .renamevent .renevent} ${ns}::renameEvent

proc mergeEvents {unick host handle dest text} {
	if {![onPollChan $unick]} { return 0 }

	if {![regexp {^\s*(-f(?:orce)?\s+)?(\d+)\s+(\d+)} $text m force oldEventIndex newEventIndex]
			|| $oldEventIndex == $newEventIndex} {
		send $unick $dest {Usage: .mergeevents [-f] <oldEventIndex> <newEventIndex>}
	} elseif {[getEvent $unick $host $dest oldEvent $oldEventIndex]
				&& [getEvent $unick $host $dest newEvent $newEventIndex]} {
		if {$force == ""} {
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
			importFights $unick $host $handle $dest ""
			send $unick $dest "Events are now merged into '[b]$newEvent(name)[/b]'."
		}
	} else {
		send $unick $dest {At least one event index you provided is invalid. Check the event listing and try again.}
	}
	return 1
}
mbind {msg pub} $adminFlag {
	.mergeevent .mergeevents .mergevent .mergevents
	.swapevent .swapevents .switchevent .switchevents
} ${ns}::mergeEvents

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
mbind {msg pub} $adminFlag {.endevent .closeevent .stopevent} ${ns}::endEvent

proc getNotes {unick host handle dest text} {
	if {![onPollChan $unick]} { return 0 }

	set id [lindex [split [string trim $text]] 0]
	set event(id) $id
	if {($id == "" && ![getEvent $unick $host "" event])
			|| ![string is digit -strict $event(id)]} {
		send $unick $dest "You must either specify an explicit event ID with\
			[b].notes <id>[/b] or first select an event with [b].event <index>[/b]."
	} else {
		db eval {SELECT name, start_date AS date, notes FROM events WHERE id = :event(id)} r {}
		if {[array size r] > 1} {
			set title "[b]$r(name)[/b] ([formatShortDate $r(date)])"
			if {$r(notes) == ""} {
				send $unick $dest "There are no notes set for $title."
			} else {
				send $unick $dest "Notes for $title:"
				send $unick $dest $r(notes)
				if {$id == ""} {
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
	if {$text == ""} {
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
mbind {msg pub} $adminFlag {.unsetnote .unsetnotes .clearnote .clearnotes} ${ns}::clearNotes

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
mbind {msg pub} $adminFlag {.sayevent .announceevent} ${ns}::announceEvent

proc listFights {unick host handle dest {text ""} {showUsage 0}} {
	if {![onPollChan $unick]} { return 0 }

	variable adminFlag
	if {[getEvent $unick $host $dest event]} {
		clearFights $unick $host

		set user [expr {$text == "" ? $unick : [string trim $text]}]
		set you [string equal -nocase $user $unick]
		set rows [db eval {
			SELECT fights.id, fighter1, fighter2, fighter1_odds, fighter2_odds,
				fights.result, notes, locked, pick, vote FROM fights
				LEFT JOIN picks ON fights.id = picks.fight_id
				AND picks.user_id IN(SELECT id FROM users WHERE nick = :user)
				WHERE event_id = :event(id) ORDER BY fights.id;
		}]
		set totalFights [expr [llength $rows] / 10]
		if {$totalFights} {

			set numFormat [getNumFormat $totalFights]
			set lines {}
			set totalPicks 0
			set index 0
			foreach {fightId fighter1 fighter2 odds1 odds2 result notes locked pick vote} $rows {
				incr index
				setFight $unick $host $event(index) $index $fightId $fighter1 $fighter2
				set resultId -1
				if {$result != ""} {
					set resultId 0
					if {[string equal -nocase $fighter1 $result]} {
						set resultId 1
					} elseif {[string equal -nocase $fighter2 $result]} {
						set resultId 2
					}
				}
				set mark ""
				if {$vote != ""} {
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

				if {$odds1 != ""} {
					set odds1 [format " <[expr {$odds1 == 0 ? "EV" : "%+d"}]>" $odds1]
				}
				if {$odds2 != ""} {
					set odds2 [format " <[expr {$odds2 == 0 ? "EV" : "%+d"}]>" $odds2]
				}

				set resultLine [format "[b]$numFormat[/b]. %s%s%s vs. %s%s%s%s"\
					$index $fighter1 $odds1 $result1 $fighter2 $odds2 $result2 $other]
				if {$locked} {
					set message ""
					if {$resultId == -1} {
						set message "PENDING RESULTS"
					}
					if {$notes != "" && $message != ""} {
						append resultLine " :: \[ $notes | $message \]"
					} elseif {"$notes$message" != ""} {
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
			if {$picks != ""} {
				send $unick $dest $picks
			}
			foreach line $lines {
				send $unick $dest $line
			}
			if {($totalPicks == 0 && $you) || $showUsage} {
				send $unick $dest "Type [b].pick <index><a|b>\[~\][/b] to make your picks.  Multi-pick example: .pick 1b 2a~ 4b"
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
		if {$notes != ""} {
			send $unick $dest "[b]*[/b] $notes"
		}
	}
	return 1
}
mbind {msg pub} - {.fights .listfights .showfights} ${ns}::listFights

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
			if {[string toupper [string index $odds1 0]] == "E"} {
				set odds1 0
			}
			if {[string toupper [string index $odds2 0]] == "E"} {
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
		if {$force == ""} {
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
		set who "fighter[expr {$which == "a" || $which == "A" ? 1 : 2}]"
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
mbind {msg pub} $adminFlag {.renamefight .renfight .renamefighter .renfighter} ${ns}::renameFighter

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
mbind {msg pub} $adminFlag {.lock .lockfight} [list ${ns}::lockFight 1]
mbind {msg pub} $adminFlag {.unlock .unlockfight} [list ${ns}::lockFight 0]

proc findFights {unick host handle dest query} {
	if {![onPollChan $unick]} { return 0 }

	if {[set query [string trim $query]] == "" ||
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
			} elseif {$result != ""} {
				set fight "$fighter1 vs. $fighter2 was a [string range $result 1 end]"
			} else {
				set fight "$fighter1 vs. $fighter2"
			}
			if {$notes != ""} {
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
		set voted [expr {$type == ""}]
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
					if {$fighter1Votes == ""} {
						set fighter1Votes 0
					}
					if {$fighter2Votes == ""} {
						set fighter2Votes 0
					}
					set totalVotes [expr $fighter1Votes + $fighter2Votes]
					if {$totalVotes > 0} {
						set fighter1Percentage [format "%.0f%%" [expr ($fighter1Votes / double($totalVotes)) * 100]]
						set fighter2Percentage [format "%.0f%%" [expr ($fighter2Votes / double($totalVotes)) * 100]]
						mmsg [list\
							"[b]$fighter1[/b] ($fighter1Votes/$fighter1Percentage) vs.\
							[b]$fighter2[/b] ($fighter2Votes/$fighter2Percentage)"\
							"$totalVotes vote[s $totalVotes] locked in.  Results after fight is over."] $eventName
					} else {
						mmsg [list "Time's up!  No one voted on [b]$fighter1[/b] vs. [b]$fighter2[/b]."] $eventName
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
			mmsg [list\
				"[b]$fighter1[/b] vs. [b]$fighter2[/b]"\
				"!1 -> $fighter1"\
				"!2 -> $fighter2"\
				"Voting !1~ or !2~ will not affect your stats."\
			] $eventName
			set pollTimer [utimer $pollInterval [list ${ns}::runAnnouncement [expr $seconds - $pollInterval]]]
		} else {
			endPoll
		}
	}
}

proc startPoll {unick host handle dest index} {
	if {![onPollChan $unick]} { return 0 }

	variable poll
	variable pollDuration

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
		runAnnouncement [expr $pollDuration * 60]
	}
	return 1
}
mbind {msg pub} $adminFlag {.poll .pollstart .startpoll .sayfight .announcefight .announce} ${ns}::startPoll

proc stopPoll {unick host handle dest text} {
	if {![onPollChan $unick]} { return 0 }

	endPoll
	return 1
}
mbind {msg pub} $adminFlag {.stop .pollstop .stoppoll .endpoll .pollend .cancelpoll .pollcancel} ${ns}::stopPoll

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
			if {$notes != ""} {
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
						[s $totalWinners] [expr ($totalWinners / double($totalVotes)) * 100] $winners]\
					[format "Loser%s (%.0f%%): %s"\
						[s $totalLosers] [expr ($totalLosers / double($totalVotes)) * 100] $losers]\
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
					append congrats " Type [b].topstreaks[/b] for the best win streaks of all time."
					lappend messages $congrats
				}
				if {[info exists newRankLeaders]} {
					lappend messages "[b]\[NEW LEADER\][/b] Congratulations,\
						[b][join [lsort -dictionary $newRankLeaders] "[/b], [b]"][/b]!\
						You are now [b]#1[/b] at the top of the leaderboard rankings!\
						Type [b].rankings[/b] to see the current standings."
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
mbind {msg pub} $adminFlag {
	.sayresult .sayresults .saywinner .announcewinner .announceresult .announceresults .result .results
} ${ns}::announceResult

proc announceOther {result unick host handle dest notes} {
	if {![onPollChan $unick]} { return 0 }

	if {$notes != ""} {
		append result "; $notes"
	}
	return [announceResult $unick $host $handle $dest "$result"]
}
mbind {msg pub} $adminFlag {.saydraw .announcedraw} [list ${ns}::announceOther "draw"]
mbind {msg pub} $adminFlag {.saync .announcenc} [list ${ns}::announceOther "nc"]
mbind {msg pub} $adminFlag {.saynd .announcend} [list ${ns}::announceOther "nd"]

proc allowPick {unick dest eventName eventDate} {
	variable minPickDateDiff
	set eventTime [clock scan $eventDate -base [unixtime] -gmt 1]
	if {[expr ($eventTime - [unixtime]) / (60 * 60)] < $minPickDateDiff} {
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
			if {$userId == ""} {
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
						if {[string index $which 0] == "b"} {
							set winner $fight(fighter2)
							set loser $fight(fighter1)
						}
						set vote [expr {[string index $which 1] != "~"}]
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
mbind {msg pub} - {.pick .vote .addpick .addvote} ${ns}::pick

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
					cannot be removed.  Either you had no pick for this fight or the fight already started."
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
		if {$user == "" ||
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
	if {$fighter1 == "" && $fighter2 == "" && $eventRE == ""} {
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
		set totalEvents [expr [llength $events] / 3]
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
		if {$query == ""} {
			send $unick $dest "$who no$recent picks."
		} else {
			send $unick $dest "$who no$recent picks matching those search criteria: $query"
		}
	}
	return 1
}
mbind {msg pub} - {.picks .findpick .findpicks} ${ns}::findPicks

proc whoPicked {unick host handle dest query} {
	if {![onPollChan $unick]} { return 0 }

	if {![regexp -nocase {^\s*([^@%_]+?)\s*(?:\s(vs?\.?|over)\s+([^@%_]+?)\s*)?(?:@\s*(.+?)\s*)?\s*$}\
				$query m fighter1 searchType fighter2 eventRE]
	} {
		send $unick $dest {Usage: .whopicked <fighter1> [<vs | over> fighter2][@ eventRE]}
	} else {
		set fighter1Glob "$fighter1%"
		set fighter2Glob [expr {$fighter2 == "" ? "" : "$fighter2%"}]
		set sql {
			SELECT GROUP_CONCAT(nick) AS nicks, pick,
				(CASE WHEN pick = fighter1 THEN fighter2 ELSE fighter1 END) AS opponent,
				event_name AS eventName, event_start_date AS eventDate FROM vw_picks
				WHERE ((fighter1 LIKE :fighter1Glob AND fighter2 REGEXP :fighter2)
				OR (fighter1 LIKE :fighter2Glob AND fighter2 REGEXP :fighter1)
				OR (fighter2 LIKE :fighter1Glob AND fighter1 REGEXP :fighter2)
				OR (fighter2 LIKE :fighter2Glob AND fighter1 REGEXP :fighter1))
		}
		if {[string equal -nocase $searchType "over"] || $searchType == ""} {
			lappend sql AND pick REGEXP :fighter1
		}
		lappend sql AND event_name REGEXP :eventRE GROUP BY fight_id, pick
		db eval $sql {
			set picks($eventDate\n$eventName\n$pick\n$opponent) $nicks
		}
		if {[info exists picks]} {
			foreach key [lsort -dictionary [array names picks]] {
				foreach {eventDate eventName pick opponent} [split $key \n] {
					set nicks [split $picks($key) ,]
					set totalUsers [llength $nicks]
					send $unick $dest "$totalUsers user[s $totalUsers]\
						picked [b]$pick[/b] over [b]$opponent[/b]\
						at $eventName ([formatWordDate $eventDate 0]):"
					send $unick $dest "  [join [lsort -dictionary $nicks] ", "]"
				}
			}
		} else {
			send $unick $dest "No one picked $query."
			send $unick $dest "NOTE: At least one parameter must begin with the fighter's [b]FIRST[/b] name."
		}
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
		if {$targetUser == ""} {
			send $unick $dest "Target user '[b]$target[/b]' does not exist."
		} else {
			set dupes [lrange $nicks 1 end]
			set totalDupes [llength $dupes]

			if {$force == ""} {
				set targetNick [lindex $targetUser 1]
				send $unick $dest "This action will merge the stats and picks from\
					[expr $totalDupes + 1] users and permanently [u]remove[/u]\
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
#	SELECT GROUP_CONCAT(user_id), ROUND(rating, 4) AS r FROM vw_stats
#		GROUP BY r, streak ORDER BY r DESC, streak DESC;

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

	if {[set user [string trim $user]] == ""} {
		set user $unick
	}
	updateRankings
	set msg ""

	db eval {
		SELECT users.nick, users.wins, users.losses, users.streak,
			users.best_streak AS bestStreak, rating, rank
			FROM rankings INNER JOIN users ON user_id = users.id WHERE users.nick = :user;
	} {
		set winPercent [expr round(($wins / double($wins + $losses)) * 100)]
		set lossPercent [expr 100 - $winPercent]
		set msg [format	"%s >> rank #%d, rating %.3f, %d win%s (%d%%), %d loss%s (%d%%), streak %+d"\
			$nick $rank $rating $wins [s $wins] $winPercent $losses [s $losses "es"] $lossPercent $streak]
		if {$bestStreak > 0} {
			append msg [format " (%+d personal best)" $bestStreak]
		}
	}
	if {$msg != ""} {
		if {$args == {}} {
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
		lappend users [format "#%d [b]%s[/b] -- R:%.3f W:%d L:%d (%.0f%%) %+d"\
			$rank $nick $rating $wins $losses [expr ($wins / double($wins + $losses)) * 100] $streak]
	}
	set totalResults [llength $users]
	if {$totalResults} {
		send $unick $dest "[b][u]FIGHT PICK RANKINGS[/u][/b]"
		foreach user $users {
			send $unick $dest $user
		}
		if {$totalResults == $limit} {
			send $unick $dest "For the next $limit results, type:\
				[b]$trigger[expr $offset + $limit] $maxRank[/b]"
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
		lappend users [format "%+d [b]%s[/b]  #%d" $streak $nick $rank]
	}
	set totalResults [llength $users]
	if {$totalResults} {
		send $unick $dest "[b]Win/Loss Streaks:[/b]"
		foreach user $users {
			send $unick $dest $user
		}
		if {$totalResults == $limit} {
			send $unick $dest "For the next $limit results, type:\
				[b]$trigger[expr $offset + $limit] $maxStreak[/b]"
		}
	} elseif {$offset > 0 || $maxStreak > 0} {
		send $unick $dest "No more results."
	} else {
		send $unick $dest "No one is on a win streak!  You guys suck."
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
	set totalRecords [expr [llength $streaks] / 3]
	if {$totalRecords} {
		send $unick $dest "[b][u]TOP 5 WIN STREAKS OF ALL TIME[/u][/b]"
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
mbind {msg pub} - {
	.best .beststreaks .top .topstreak .topstreaks .records .recordstreaks
} ${ns}::bestStreaks

proc worstStreaks {unick host handle dest text} {
	if {![onPollChan $unick]} { return 0 }

	set streaks [db eval {
		SELECT GROUP_CONCAT(nick), ABS(worst_streak), STRFTIME('%m/%d/%Y', MIN(worst_streak_date))
			FROM users WHERE worst_streak < -1 GROUP BY worst_streak
			ORDER BY worst_streak LIMIT 5
	}]
	set totalRecords [expr [llength $streaks] / 3]
	if {$totalRecords} {
		send $unick $dest "[b][u]THE 5 WORST STREAKS OF ALL TIME[/u][/b]"
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

proc searchSherdogFightFinder {unick host handle dest text} {
	if {![onPollChan $unick]} { return 0 }

	variable ns
	variable sherdog

	set query [string trim $text]
	if {$query == ""} {
		send $unick $dest "Usage: .sherdog <fighter>"
	} else {
		set url "http://www.google.com/search?"
		append url [http::formatQuery num 1 as_qdr all as_sitesearch www.sherdog.com as_q "\"fight finder\" $query"]
		send $unick $dest "Searching Sherdog Fight Finder for '$query'.  Please wait..."

		array unset sherdog
		http::config -useragent "Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 6.2; Trident/4.0)"
		if {[catch {parseHTML [http::data [geturlex $url]] ${ns}::parseGoogleForSherdog} error]} {
			send $unick $dest "Search error: $error"
		} elseif {![info exists sherdog(url)]} {
			send $unick $dest "Google failed to return a Sherdog Fight Finder URL.\
				Try again later or change the query a bit."
		} else {
			if {[catch {parseHTML [http::data [geturlex $sherdog(url)]] ${ns}::parseSherdogFightFinder} error]} {
				send $unick $dest "Failed to download Sherdog content at $sherdog(url): $error"
			} elseif {![info exists sherdog(headers)] && ![info exists sherdog(record)]} {
				send $unick $dest "Failed to parse Sherdog content at $sherdog(url)"
			} else {
				set name $query
				regsub -all {"\s+(.*?)\s+"} $sherdog(name) {"\1"} fighter
				send $unick $dest "[b][u][string trim $fighter][/u][/b]"
				foreach bio $sherdog(profile) {
					regsub {^\s*(Birthday|Height|Weight|Association|Class|Wins|Losses|N/C):?} $bio "[b]\\1[/b]:" bio
					send $unick $dest "  $bio"
				}
				foreach stat $sherdog(record) {
					regsub -all {\(\s+(\S+)\s+\)} $stat {(\1)} stat
					regsub {^(\S+)\s+(\d+)} $stat "[b]\\1[/b]: \\2" stat
					regsub {^(\S+\s+\d+)\s+(.*)} $stat {\1 | \2} stat
					send $unick $dest "  $stat"
				}
				if {[llength $sherdog(history)]} {
					send $unick $dest " "
					set i 0
					foreach fight $sherdog(history) {
						foreach {result opponent event method round time} $fight {
							send $unick $dest [format "%3d. %-4s | [b]%s[/b] | %s | %s | Round %s | %s"\
								[incr i] [string toupper $result 0 0] $opponent $event $method $round $time]
						}
					}
				}
				send $unick $dest " "
				send $unick $dest "Sherdog Fight Finder page for $name: [b]$sherdog(url)[/b]"
			}
		}
	}

	array unset sherdog
	return 1
}
mbind {msg pub} - {.sherdog .fightfinder} ${ns}::searchSherdogFightFinder

proc parseGoogleForSherdog {tagtype state props body} {
	variable sherdog
	set tag "$state$tagtype"
	if {$tag == "a" && [regexp -nocase {href="?(http://www\.sherdog\.com/fighter/[^" ]+)} $props m url]} {
		set sherdog(url) $url
	}
}

proc parseSherdogFightFinder {tagtype state props body} {
	variable sherdog
	set tag "$state$tagtype"

	if {$tag == "h2" && $body == "Amateur Fights"} {
		set sherdog(state) ""
		set sherdog(done) 1
		return
	} elseif {[info exists sherdog(done)]} {
		return
	}

	if {$tag == "hmstart"} {
		array unset sherdog "done"
		set sherdog(state) ""
		set sherdog(name) ""
		set sherdog(profile) {}
		set sherdog(record) {}
		set sherdog(history) {}
	} elseif {$props == {class="module bio_fighter"}} {
		set sherdog(state) "findH1"
	} elseif {[string match {class="item*} $props]} {
		set sherdog(state) "profile"
		if {[info exists sherdog(bio)]} {
			lappend sherdog(profile) [string range $sherdog(bio) 1 end]
			array unset sherdog "bio"
		}
	} elseif {[string match {class="bio_graph*} $props]} {
		set sherdog(state) "record"
		if {[info exists sherdog(bio)]} {
			lappend sherdog(profile) [string range $sherdog(bio) 1 end]
			array unset sherdog "bio"
		}
		if {[info exists sherdog(stat)]} {
			lappend sherdog(record) [string range $sherdog(stat) 1 end]
			array unset sherdog "stat"
		}
	} elseif {$props == {class="module fight_history"}} {
		set sherdog(state) "startHistory"
		if {[info exists sherdog(stat)]} {
			lappend sherdog(record) [string range $sherdog(stat) 1 end]
			array unset sherdog "stat"
		}
	} elseif {$tag == "tr" && $props == {class="odd"} || $props == {class="even"}} {
		if {$sherdog(state) == "startHistory"} {
			set sherdog(state) "history"
		}
	} elseif {$tag == "/tr" && $sherdog(state) == "history"} {
		if {[info exists sherdog(fight)]} {
			if {[info exists sherdog(history)]} {
				set sherdog(history) [linsert $sherdog(history) 0 $sherdog(fight)]
			} else {
				lappend sherdog(history) $sherdog(fight)
			}
			array unset sherdog "fight"
			array unset sherdog "cell"
		}
	}

	switch $sherdog(state) {
		findH1 {
			if {$tag == "h1"} {
				set sherdog(state) "name"
				set body [string trim [htmlDecode $body]]
				if {$body != ""} {
					append sherdog(name) " $body"
				}
			}
		}
		name {
			set body [string trim [htmlDecode $body]]
			if {$body != ""} {
				append sherdog(name) " $body"
			}
			if {$tag == "/h1"} {
				set sherdog(state) ""
			}
		}
		profile {
			set body [string trim [htmlDecode $body]]
			if {$body != ""} {
				append sherdog(bio) " $body"
			}
		}
		record {
			set body [string trim [htmlDecode $body]]
			if {$body != ""} {
				append sherdog(stat) " $body"
			}
			if {$tag == "/div"} {
				set sherdog(state) ""
			}
		}
		history {
			if {$tag == "/table"} {
				set sherdog(state) ""
				set sherdog(done) 1
			} else {
				set body [string trim [htmlDecode $body]]
				if {$body != ""} {
					if {$props == {class="sub_line"}} {
						append sherdog(cell) " ::"
						regsub -all {\s+/\s+} $body {/} body
					}
					append sherdog(cell) " $body"
				}
				if {$tag == "/td" && [info exists sherdog(cell)]} {
					lappend sherdog(fight) [string range $sherdog(cell) 1 end]
					array unset sherdog "cell"
				}
			}
		}
	}
}

proc help {unick host handle dest text} {
	if {![onPollChan $unick]} { return 0 }

	variable adminFlag
	variable scriptVersion

	send $unick $dest "[b][u]FIGHT POLL $scriptVersion HELP[/u][/b]"

	foreach {access line} [concat {
		@ {.importfights .................................. Import fights and betting lines from the web}
		- {.events ........................................ Show all upcoming fight events}
		- {.event <index> ................................. Select event as command context}
		@ {.addevent <eventName>[; yyyy-MM-dd HH:mm Z] .... Add fight event to be held on specified date}
		@ {.delevent <index> .............................. Delete fight event at specified index}
		@ {.renameevent <index> <newEventName> ............ Rename event at specified index}
		@ {.mergeevents <oldEventIndex> <newEventIndex> ... Merge events (new event is deleted; old one is renamed)}
		@ {.endevent ...................................... Remove event from upcoming events list}
		- {.findevent[offset[,limit]] <eventRE> ........... Find an event matching the given regex}
		- {.notes [id] .................................... Show notes for selected or specified event}
		@ {.setnotes <text> ............................... Set notes for selected event}
		@ {.clearnotes .................................... Clear notes from selected event}
		@ {.sayevent ...................................... Announce selected event}
		- {.fights [user] ................................. List fights for selected event with picks from user}
		@ {.addfight f1 [<+-odds1>] vs f2 [<+-odds2>] ..... Add fight to selected event}
		@ {.delfight <index> .............................. Delete fight at index from selected event}
		@ {.renamefighter <index><a|b> <newFighterName> ... Rename specified fighter}
		@ {.lock <index> .................................. Lock fight at index to disallow .pick on it}
		@ {.unlock <index> ................................ Unlock fight at index to allow .pick on it}
		- {.findfight [f1RE [vs f2RE]][@ eventRE] ......... Show info for matching fights}
		@ {.poll <index> .................................. Start polling for selected fight index}
		@ {.stop .......................................... Stop polling}
		@ {.setresult <index> <1|2|draw|nc|nd> [notes] .... Set result of fight at index}
		@ {.sayresult <1|2|draw|nc|nd> [notes] ............ Announce result of last announced fight}
		@ {.saydraw [notes] ............................... Alias for .sayresult draw}
		@ {.saync [notes] ................................. Alias for .sayresult nc}
		@ {.saynd [notes] ................................. Alias for .sayresult nd}
		- {.whopicked <f1> [<vs|over> f2][@ eventRE] ...... Show who picked a particular fighter}
		- {.picks <user> [f1RE [vs f2RE]][@ eventRE] ...... Show user picks for matching events/fights}
		- {.pick <index><a|b>[~][ <indexN><a|b>[~]] ....... Pick fighter at index to win from selected event}
		- {.delpick <index> ............................... Delete pick for selected event}
		@ {.merge <targetNick> <nick1>[ nickN] ............ Delete nick(s) and merge their picks/stats into target}
		- {.stats [user] .................................. Show stats for specified user}
		- {.rankings[offset[,limit]] [maxRank] ............ Show fight pick rankings}
		- {.streaks[offset[,limit]] [maxStreak] ........... Show current win streak rankings}
		- {.topstreaks .................................... Show top 5 win streaks of all time}
		- {.worststreaks .................................. Show the 5 worst streaks of all time}
		- {.sherdog <fighter> ............................. Display Sherdog Fight Finder records}
		- {.help .......................................... Display this help information}
		- { }} [list\
		- "NOTES: \"RE\" suffix indicates a regular expression.  All times are [timezone]."] {
		- { }
	}] {
		if {$access == "-" || [matchchanattr $handle $adminFlag $dest]} {
			send $unick $dest $line
		}
	}

	send $unick $dest "End of help."
	return 1
}
mbind {msg pub} - {.help .fighthelp .fightshelp .helpfight .helpfights} ${ns}::help

if {[catch {init} error]} {
	die $error
}
registerCleanup ${ns} ${ns}::db


putlog "[b]Fight Poll TCL $scriptVersion by makk loaded![/b]"

}
