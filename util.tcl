####################################################################
#
# File: util.tcl
#
# Description: Utility library of common functions
#
# Author: makk@EFnet
#
# Release Date: May 14, 2010
#  Last Update: Jul 28, 2011
#
####################################################################

package require uri
package provide util 1.0

namespace eval ::util:: {
	namespace export -clear loadDatabase s populate tz timeDiff toGMT toLocal\
		now currentYear timezone formatShortDate formatDateTime formatWordDate\
		formatWordDateTime put putMessage putNotice putAction mbind logStackable\
		c /c b /b r /r u /u bindSQL scheduleBackup registerCleanup htmlDecode\
		parseHTML geturlex

	variable ns [namespace current]
	variable maxMessageLen 510
	variable maxLineWrap   5  ;# max lines to wrap when text is too long
	variable floodSupport  0
	variable tz            ":America/New_York"  ;# "-0500"

	if {[catch {clock scan 0 -timezone $tz}]} {
		set ::util::tz "-0500"
	}
}

proc ::util::loadDatabase {db database {sqlScripts {}}} {
	global tcl_platform
	variable ns

	foreach item [concat $database $sqlScripts] {
		catch {exec chmod 600 $item}
	}

	if {[catch {
		if {$tcl_platform(platform) == "unix"} {
			load "[pwd]/tclsqlite3.so" "tclsqlite3"
		} else {
			load "[pwd]/tclsqlite3.dll" "tclsqlite3"
		}
		sqlite3 $db $database
	} error]} {
		return -code error "*** Failed to open database '$database': $error"
	}

	foreach script $sqlScripts {
		if {[catch {set f [open $script r]} error]} {
			return -code error "*** Failed to open SQL script '$script': $error"
		} else {
			catch {$db eval [read $f]}
			catch {close $f}
		}
	}

	catch {$db function REGEXP ${ns}::regexpSQL}
	return 1
}

proc ::util::s {quantity {suffix "s"}} {
	return [expr {$quantity == 1 ? "" : $suffix}]
}

proc ::util::regexpSQL {expr text} {
	if {[catch {set ret [regexp -nocase -- $expr $text]}]} {
		# invalid expression
		return 0
	}
	return $ret
}

# add list placeholder support - ex: db eval [populate {SELECT * FROM t WHERE u IN(::var)}]
proc ::util::populate {sql} {
	set s ""
	set pos 0
	foreach {first last} [join [regexp -all -indices -inline {::[\w$]+} $sql]] {
		append s [string range $sql $pos [expr $first - 1]]
		set var [string range $sql [expr $first + 2] $last]
		upvar $var list
		if {[info exists list]} {
			set varName "${var}$"
			upvar $varName a
			array unset a *
			set items {}
			set i 0
			foreach item $list {
				set a($i) $item
				lappend items ":${varName}($i)"
				incr i
			}
			append s [join $items ,]
		} else {
			append s "NULL"
		}
		set pos [expr $last + 1]
	}
	return [append s [string range $sql $pos end]]
}

proc ::util::tz {} {
	variable tz
	return $tz
}

# Some sort of Eggdrop/TCL bug results in clock changes not updating properly,
# so we anchor at [unixtime] to be safe

proc ::util::timeDiff {date1 {future "away"} {past "ago"}} {
	set secs [expr [clock scan $date1 -base [unixtime] -gmt 1] - [unixtime]]
	set rel  [expr {$secs < 0 ? $past : $future}]
	set secs [expr abs($secs)]
	set days [expr $secs / (60 * 60 * 24)]
	set secs [expr {$days ? 0 : $secs % (60 * 60 * 24)}]
	set hrs  [expr $secs / (60 * 60)]
	set secs [expr $secs % (60 * 60)]
	set mins [expr $secs / 60]
	set secs [expr {($hrs || $mins) ? 0 : $secs % 60}]
	foreach {value unit} [list $days d $hrs h $mins m $secs s] {
		if {$value > 0} {
			append text "$value$unit "
		}
	}
	return [expr {[info exists text] ? "$text$rel" : "NOW"}]
}

proc ::util::toGMT {{date ""}} {
	return [clock format [clock scan $date -base [unixtime] -timezone [tz]] -format "%Y-%m-%d %H:%M:%S" -gmt 1]
}

proc ::util::toLocal {{date ""}} {
	return [clock format [clock scan $date -base [unixtime] -gmt 1] -format "%Y-%m-%d %H:%M:%S" -timezone [tz]]
}

proc ::util::now {{gmt 1}} {
	return [expr {$gmt ? [toGMT] : [toLocal]}]
}

proc ::util::currentYear {} {
	return [clock format [unixtime] -format "%Y" -timezone [tz]]
}

proc ::util::timezone {{withOffset 0}} {
	return [clock format [unixtime] -format "%Z[expr {$withOffset ? " %z" : ""}]" -timezone [tz]]
}

proc ::util::validTimeZone {tz} {
	set timezones {
		gmt ut utc bst wet wat at nft nst ndt ast adt est edt cst cdt mst mdt
		pst pdt yst ydt hst hdt cat ahst nt idlw cet cest met mewt mest swt
		sst eet eest bt it zp4 zp5 ist zp6 wast wadt jt cct jst cast cadt
		east eadt gst nzt nzst nzdt idle
	}
	return [expr {[lsearch -exact $timezones $tz] != -1}]
}

proc ::util::wordDay {day} {
	if {[regexp {^\d+$} $day]} {
		if {$day < 11 || $day > 13} {
			switch [string index $day end] {
				1 { return "${day}st" }
				2 { return "${day}nd" }
				3 { return "${day}rd" }
			}
		}
		return "${day}th"
	}
	return $day
}

proc ::util::shortYear {utime format} {
	if {[clock format [unixtime] -format "%Y" -timezone [tz]] == [clock format $utime -format "%Y" -timezone [tz]]} {
		return ""
	}
	return $format
}

proc ::util::formatShortDate {datetime} {
	set dt [clock scan $datetime -base [unixtime] -gmt 1]
	return [string trimleft [clock format $dt -format "%m/%d[shortYear $dt "/%y"]" -timezone [tz]] 0]
}

proc ::util::formatDateTime {datetime} {
	set dt [clock scan $datetime -base [unixtime] -gmt 1]
	regsub -all {\s{2,}} [clock format $dt -format "%m/%d[shortYear $dt "/%Y"] %l:%M%P" -timezone [tz]] " " date
	return [string trimleft $date 0]
}

proc ::util::formatWordDate {datetime {formal 1}} {
	set dt [clock scan $datetime -base [unixtime] -gmt 1]
	set date [clock format $dt -format "%b %e[shortYear $dt ", %Y"]" -timezone [tz]]
	return "[lindex $date 0] [expr {$formal ? [wordDay [lrange $date 1 end]] : [lrange $date 1 end]}]"
}

proc ::util::formatWordDateTime {datetime {formal 1}} {
	set dt [clock scan $datetime -base [unixtime] -gmt 1]
	set date [clock format $dt -format "%a, %b %e[shortYear $dt ", %Y"] at %l:%M%P" -timezone [tz]]
	regsub {:00} $date "" date
	return "[lrange $date 0 1] [expr {$formal ? [wordDay [lindex $date 2]] : [lindex $date 2]}] [lrange $date 3 end]"
}

proc ::util::log {loglevel text} {
	if {$loglevel >= 1 && $loglevel <= 8} {
		return [putloglev $loglevel * $text]
	}
	return
}

proc ::util::logStackable {unick host handle dest text} {
	if {$unick == $dest} {
		putcmdlog "($unick!$host) !$handle! $text"
	} else {
		putcmdlog "<<$unick>> !$handle! $text"
	}
	return 1
}

proc ::util::initCapabilities {from keyword text} {
	variable floodSupport 0
	return 0
}
bind raw - 001 ::util::initCapabilities

proc ::util::capabilities {from keyword text} {
	variable floodSupport
	if {[lsearch -exact [split $text] "CPRIVMSG"] >= 0} {
		set floodSupport 1
	}
	return 0
}
bind raw - 005 ::util::capabilities

if {[catch {package require eggdrop 1.6.20}]} {
	proc ::putnow {text args} {
		append text "\r\n"
		return [putdccraw 0 [string length $text] $text]
	}
}

proc ::util::put {text {queue putquick} {loglevel 0} {prefix ""} {suffix ""} {ellipsis "..."}} {
	global botname
	variable maxMessageLen
	variable maxLineWrap

	set maxText [expr $maxMessageLen - [string length $botname]\
		- [string length $prefix] - [string length $suffix] - 2]

	set overflow [expr {$maxText < [string length $text]}]
	if {$overflow} {
		incr maxText -[string length $ellipsis]
	}

	set lines 0
	set l [string length $text]
	for {set i 0} {$i < $l && $lines < $maxLineWrap} {incr i $maxText} {
		set message [string range $text $i [expr $i + $maxText - 1]]
		if {$overflow} {
			set message [expr {$i ? "$ellipsis$message" : "$message$ellipsis"}]
		}
		log $loglevel "\[>\] $prefix$message$suffix"
		$queue "$prefix$message$suffix"
		incr lines
	}
	if {[string length [string range $text $i end]]} {
		$queue "$prefix\[ Message truncated to $maxLineWrap line[s $maxLineWrap]. \]$suffix"
	}
	return 0
}

proc ::util::putType {type unick dest text {queue putquick} {loglevel 0}} {
	global botnick
	variable floodSupport

	if {$floodSupport} {
		foreach chan [concat [list $dest] [channels]] {
			if {[validchan $chan] && [isop $botnick $chan] && [onchan $unick $chan]} {
				return [put $text $queue $loglevel "C$type $unick $chan :"]
			}
		}
	}
	if {[string index $dest 0] != "#" && $queue == "putnow"} {
		set queue putquick
	}
	return [put $text $queue $loglevel "$type $unick :"]
}

proc ::util::putMessage {unick dest text {queue putquick} {loglevel 0}} {
	return [putType "PRIVMSG" $unick $dest $text $queue $loglevel]
}

proc ::util::putNotice {unick dest text {queue putquick} {loglevel 0}} {
	return [putType "NOTICE" $unick $dest $text $queue $loglevel]
}

proc ::util::putAction {unick dest text {queue putquick} {loglevel 0}} {
	return [put $text $queue $loglevel "PRIVMSG $unick :\001ACTION found " "\001"]
}

proc ::util::redirect {handler unick host handle text} {
	if {[llength $handler] == 1} {
		return [$handler $unick $host $handle $unick $text]
	}
	return [[lindex $handler 0] [lrange $handler 1 end] $unick $host $handle $unick $text]
}

proc ::util::mbind {types flags triggers handler} {
	variable ns

	set totalBinds 0
	set msgHandler [list ${ns}::redirect $handler]

	foreach type $types {
		set eventHandler $handler
		if {$type == "msg" || $type == "msgm"} {
			set eventHandler $msgHandler
		}
		foreach trigger $triggers {
			if {$type == "msgm" && [llength $trigger] > 1} {
				set trigger [lrange [split $trigger] 1 end]
			}
			bind $type $flags $trigger $eventHandler
			incr totalBinds
		}
	}
	return $totalBinds
}

proc  ::util::c {color {bgcolor ""}} {
	return "\003$color[expr {$bgcolor == "" ? "" : ",$bgcolor"}]"
}
proc ::util::/c {} { return "\003" }
proc  ::util::b {} { return "\002" }
proc ::util::/b {} { return "\002" }
proc  ::util::r {} { return "\026" }
proc ::util::/r {} { return "\026" }
proc  ::util::u {} { return "\037" }
proc ::util::/u {} { return "\037" }

# for database maintenance - use with caution!
proc ::util::sql {command db handle idx query} {
	putcmdlog "#$handle# $command $query"
	if {[catch {$db eval $query row {
		set results {}
		foreach field $row(*) {
			lappend results "[b]$field[/b]($row($field))"
		}
		putdcc $idx [join $results]
	}} error]} {
		putdcc $idx "*** SQL query failed: $error"
	}
	return 0
}

proc ::util::bindSQL {command db {flags "n"}} {
	variable ns
	return [bind dcc $flags $command [list ${ns}::sql $command $db]]
}

proc ::util::backup {db dbFile loglevel minute hour day month year} {
	set backupFile "$dbFile.bak"
	log $loglevel "Backing up $dbFile database to $backupFile..."
	catch {
		$db backup $backupFile
		exec chmod 600 $backupFile
	}
	return
}

proc ::util::scheduleBackup {db dbFile {when "04:00"} {loglevel 0}} {
	variable ns
	set when [split $when ":"]
	set hour [lindex $when 0]
	set minute [lindex $when 1]
	return [bind time - "$minute $hour * * *" [list ${ns}::backup $db $dbFile $loglevel]]
}

proc ::util::cleanup {nsRef db type} {
	foreach bind [binds "*${nsRef}::*"] {
		foreach {type flags command {} handler} $bind {
			catch {unbind $type $flags $command $handler}
		}
	}
	catch {$db close}
	namespace delete $nsRef
	return
}

proc ::util::registerCleanup {nsRef db} {
	variable ns
	return [bind evnt - prerehash [list ${ns}::cleanup $nsRef $db]]
}

proc ::util::geturlex {url args} {
	http::config -useragent "Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 6.2; Trident/4.0)"

	array set URI [::uri::split $url] ;# Need host info from here
	foreach x {1 2 3 4 5} {
		if {[catch {set token [eval [list http::geturl $url] $args]}]} {
			break
		}
		if {![string match {30[1237]} [::http::ncode $token]]} {
			return $token
		}
		array set meta [set ${token}(meta)]
		set location [lsearch -inline -nocase -exact [array names meta] "location"]
		if {$location == ""} {
			return $token
		}
		array set uri [::uri::split $meta($location)]
		unset meta
		if {$uri(host) == ""} {
			set uri(host) $URI(host)
		}
		# problem w/ relative versus absolute paths
		set url [eval ::uri::join [array get uri]]
	}
	return -1
}

array set ::util::htmlEntityMap {
	quot \x22 amp \x26 lt \x3C gt \x3E nbsp \xA0 iexcl \xA1 cent \xA2 pound \xA3
	curren \xA4 yen \xA5 brvbar \xA6 sect \xA7 uml \xA8 copy \xA9 ordf \xAA
	laquo \xAB not \xAC shy \xAD reg \xAE macr \xAF deg \xB0 plusmn \xB1
	sup2 \xB2 sup3 \xB3 acute \xB4 micro \xB5 para \xB6 middot \xB7 cedil \xB8
	sup1 \xB9 ordm \xBA raquo \xBB frac14 \xBC frac12 \xBD frac34 \xBE
	iquest \xBF Agrave \xC0 Aacute \xC1 Acirc \xC2 Atilde \xC3 Auml \xC4
	Aring \xC5 AElig \xC6 Ccedil \xC7 Egrave \xC8 Eacute \xC9 Ecirc \xCA
	Euml \xCB Igrave \xCC Iacute \xCD Icirc \xCE Iuml \xCF ETH \xD0 Ntilde \xD1
	Ograve \xD2 Oacute \xD3 Ocirc \xD4 Otilde \xD5 Ouml \xD6 times \xD7
	Oslash \xD8 Ugrave \xD9 Uacute \xDA Ucirc \xDB Uuml \xDC Yacute \xDD
	THORN \xDE szlig \xDF agrave \xE0 aacute \xE1 acirc \xE2 atilde \xE3
	auml \xE4 aring \xE5 aelig \xE6 ccedil \xE7 egrave \xE8 eacute \xE9
	ecirc \xEA euml \xEB igrave \xEC iacute \xED icirc \xEE iuml \xEF eth \xF0
	ntilde \xF1 ograve \xF2 oacute \xF3 ocirc \xF4 otilde \xF5 ouml \xF6
	divide \xF7 oslash \xF8 ugrave \xF9 uacute \xFA ucirc \xFB uuml \xFC
	yacute \xFD thorn \xFE yuml \xFF
	ob \x7b cb \x7d bsl \\
	#8203 "" #x200b "" ndash - #8211 - #x2013 - mdash -- #8212 -- #x2014 --
	#x202a "" #x202c "" rlm "" circ ^ #710 ^ #x2c6 ^ tilde ~ #732 ~ #x2dc ~
	lsquo ' #8216 ' #x2018 ' rsquo ' #8217 ' #x2019 ' sbquo ' #8218 ' #x201a '
	ldquo \" #8220 \" #x201c \" rdquo \" #8221 \" #x201d \" bdquo \" #8222 \" #x201e \"
	dagger | #8224 | #x2020 | Dagger | #8225 | #x2021 |
	lsaquo < #8249 < #x2039 < rsaquo > #8250 > #x203a >
}

proc ::util::getHTMLEntity {text {unknown ?}} {
	variable htmlEntityMap
	set result $unknown
	catch {set result $htmlEntityMap($text)}
	return $result
}

proc ::util::htmlDecode {text} {
	if {![regexp & $text]} {
		return $text
	}
	regsub -all {([][$\\])} $text {\\\1} new
	regsub -all {&(#[xX]?[\da-fA-F]{1,4});} $new {[getHTMLEntity [string tolower \1] "\x26\1;"]} new
	regsub -all {([][$\\])} [subst $new] {\\\1} new
	regsub -all {&#(\d{1,4});} $new {[format %c [scan \1 %d tmp;set tmp]]} new
	regsub -all {&#[xX]([\da-fA-F]{1,4});} $new {[format %c [scan [expr "0x\1"] %d tmp;set tmp]]} new
	regsub -all {&([a-zA-Z]+);} $new {[getHTMLEntity \1]} new
	return [subst $new]
}

proc ::util::parseHTML {html {cmd testParser} {start hmstart}} {
	regsub -all \{ $html {\&ob;} html
	regsub -all \} $html {\&cb;} html
	regsub -all {\\} $html {\&bsl;} html
	set w " \t\r\n"  ;# white space
	set exp <(/?)(\[^$w>]+)\[$w]*(\[^>]*)>
	set sub "\}\n$cmd {\\2} {\\1} {\\3} \{"
	regsub -all $exp $html $sub html
	eval "$cmd {$start} {} {} {$html}"
	eval "$cmd {$start} / {} {}"
}

proc ::util::testParser {tag state props body} {
	if {$state == ""} {
		set msg "Start $tag"
		if {$props != ""} {
			set msg "$msg with args: $props"
		}
		set msg "$msg\n$body"
	} else {
		set msg "End $tag"
	}
	putlog $msg
}
