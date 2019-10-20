#! /usr/bin/env tclsh

####################################################################
#
# Module: sherdog.tcl
# Author: makk@EFnet
# Description: Sherdog Fight Finder parser
# Release Date: October 20, 2019
#
####################################################################

package require tls
package require http
package require tdom

package provide sherdog 1.0

namespace eval ::sherdog:: {
	namespace export -clear query parse print printSummary

	variable SEARCH_BASE  "https://www.bing.com/search"
	variable SEARCH_QUERY "site:sherdog.com/fighter %s"
	variable SEARCH_LINK  "sherdog.com/fighter/"
	variable HTTP_TIMEOUT 5000
}

proc ::sherdog::parse {html {url ""}} {
	# hack to clean up malformed html that breaks the parser
	regsub -all {(?:/\s*)+(?=/\s*>)} $html "" html
	set dom [dom parse -html $html]
	set doc [$dom documentElement]

	set fighter [list\
		name [select $doc {//h1//*[contains(@class, 'fn')]}]\
		nickname [select $doc {//h1//*[contains(@class, 'nickname')]//*}]\
		birthDate [select $doc {//*[@itemprop='birthDate']} date]\
		height [select $doc {//*[@itemprop='height']}]\
		weight [select $doc {//*[@itemprop='weight']}]\
		weightClass [select $doc {//*[contains(@class, 'wclass')]//a}]\
		nationality [select $doc {//*[@itemprop='nationality']}]\
		association [select $doc {//*[contains(@class, 'association')]//strong}]\
		url [regsub {\#.*} $url ""]\
		age ""\
	]

	dict with fighter {
		if {$birthDate != "" && ![catch {set dt [clock scan $birthDate]}]} {
			set age [expr ([clock seconds] - $dt) / (60 * 60 * 24 * 365)]
		}
	}

	set upcoming [$doc selectNodes {//*[contains(@class, 'event-upcoming')]}]
	if {$upcoming != ""} {
		dict set fighter fights upcoming [list\
			event [select $upcoming {.//h2}]\
			date [select $upcoming {.//h4/node()} date "%B %d, %Y"]\
			location [select $upcoming {.//*[@itemprop='address']}]\
			opponent [select $upcoming {.//*[contains(@class, 'right_side')]//*[@itemprop='name']}]\
			opponentRecord\
				[regsub -all {\s+}\
					[select $upcoming {.//*[contains(@class, 'right_side')]//*[contains(@class, 'record')]}]\
				""]\
		]
	}

	foreach {id type} [list pro "Pro" proEx "Pro Exhibition" amateur "Amateur"] {
		set fights [$doc selectNodes [subst -nocommands {
			//*[contains(@class, 'fight_history')][.//h2[text() = 'Fight History - $type']]//tr[position() > 1]
		}]]

		set totalFights [llength $fights]
		if {$totalFights == 0} {
			continue
		}

		set history {}
		set wins 0
		set losses 0
		set draws 0
		set other 0

		foreach row $fights {
			set result [string tolower [select $row {td[1]}]]

			lappend history [list\
				result $result\
				opponent [select $row {td[2]}]\
				event [select $row {td[3]//a}]\
				date [select $row {td[3]//*[contains(@class, 'sub_line')]} date "%b / %d / %Y"]\
				method [select $row {td[4]/node()}]\
				ref [select $row {td[4]//*[contains(@class, 'sub_line')]}]\
				round [select $row {td[5]}]\
				time [select $row {td[6]}]\
			]

			switch -- $result {
				win { incr wins }
				loss { incr losses }
				draw { incr draws }
				default { incr other }
			}
		}

		set winPct [expr round(($wins / double($totalFights)) * 100)]
		set lossPct [expr round(($losses / double($totalFights)) * 100)]
		set drawPct [expr round(($draws / double($totalFights)) * 100)]
		set otherPct [expr 100 - ($winPct + $lossPct + $drawPct)]
		set record [list\
			wins $wins losses $losses draws $draws other $other\
			winPct $winPct lossPct $lossPct drawPct $drawPct otherPct $otherPct\
		]

		dict set fighter fights $id record $record
		dict set fighter fights $id history [lreverse $history]
	}

	return $fighter
}

proc ::sherdog::query {query {output -v} args} {
	variable SEARCH_BASE
	variable SEARCH_QUERY
	variable SEARCH_LINK

	set data {}
	set searchResults [fetch $SEARCH_BASE q [format $SEARCH_QUERY $query]]
	set url [findLink $searchResults $SEARCH_LINK]
	if {$url == ""} {
		throw "NO_MATCH" "No match for '$query' in the Sherdog Fight Finder."
	}

	set html [fetch $url]
	set data [parse $html $url]

	switch -- $output {
		-v - -verbose - -f - -full - -l - -long {
			set data [print $data {*}$args]
		}
		-s - -short - -summary {
			set data [printSummary $data {*}$args]
		}
	}

	return $data
}

proc ::sherdog::print {fighter {maxColSizes {}}} {
	set output {}

	dict with fighter {
		add output "[b][u]%s[/u][/b]" [expr {$nickname == "" ? $name : "$name \"$nickname\""}]
		add output "  [b]AGE[/b]: %s (%s)" $age $birthDate
		add output "  [b]HEIGHT[/b]: %s" $height
		add output "  [b]WEIGHT[/b]: %s (%s)" $weight $weightClass
		add output "  [b]NATIONALITY[/b]: %s" $nationality
		add output "  [b]ASSOCIATION[/b]: %s" $association
	}

	foreach {id title} {amateur "AMATEUR" proEx "PRO EXHIBITION" pro "PRO"} {
		if {[dict exists $fighter fights $id history]} {
			dict with fighter fights $id record {
				addn output "[b]%s FIGHTS[/b]: %d-%d-%d-%d (%d%%-%d%%-%d%%-%d%%)"\
					$title $wins $losses $draws $other $winPct $lossPct $drawPct $otherPct
			}

			set i 0
			set history [dict get $fighter fights $id history]
			set maxCountSpace [string length [llength $history]]
			set data {}

			foreach fight $history {
				dict with fight {
					add data "%${maxCountSpace}d. %s | [b]%s[/b] | %s | %s | %s | %s | R%s | %s"\
						[incr i] [formatResult $result] $opponent $event $date $method $ref $round $time
				}
			}

			if {[llength $maxColSizes]} {
				lappend output {*}[tabulate $data $maxColSizes]
			} else {
				lappend output {*}$data
			}
		}
	}

	if {[dict exists $fighter fights upcoming]} {
		dict with fighter fights upcoming {
			addn output "[b]NEXT OPPONENT[/b]: [b]%s[/b] (%s) | %s | %s | %s"\
				$opponent $opponentRecord $event $date $location
		}
	}

	if {$url != ""} {
		addn output "Source: [b]%s[/b]" [dict get $fighter url]
	}

	return $output
}

proc ::sherdog::printSummary {fighter {limit 0} {maxColSizes {}}} {
	set output {}
	set chart ""
	set record ""

	if {[dict exists $fighter fights pro]} {
		dict with fighter fights pro record {
			set record [format "%s-%s-%s-%s" $wins $losses $draws $other]
		}

		foreach fight [lrange [dict get $fighter fights pro history] end-19 end] {
			dict with fight {
				switch -- $result {
					win - w   {append chart W}
					loss - l  {append chart L}
					draw - md {append chart D}
					nc - nd   {append chart N}
				}
			}
		}
	}

	dict with fighter {
		add output "[b]%s[/b]%s %s %s %s %s"\
			$name [expr {$nickname == "" ? "" : " \"$nickname\""}]\
			$record $chart [expr {$age == "" ? "" : "${age}yo"}] $url
	}

	if {$limit > 0} {
		set results {}
		set list [lrange [lreverse [dict get $fighter fights pro history]] 0 $limit-1]

		foreach fight $list {
			dict with fight {
				add results "%s [b]%s[/b] | %s | %s | R%s/%s | %s"\
					[formatResult $result] $opponent $event $date $round $time $method
			}
		}

		lappend output {*}[tabulate $results $maxColSizes]
	}

	if {[dict exists $fighter fights upcoming]} {
		dict with fighter fights upcoming {
			add output "Next opponent: [b]%s[/b] (%s) on %s at %s"	$opponent $opponentRecord\
				[clock format [clock scan $date] -format "%b%e"] $event
		}
	}

	return $output
}

proc ::sherdog::formatResult {result} {
	set ret $result

	switch -- $result {
		win - w       {set ret "[b][c 1 03]W[/c][/b]"}
		loss - l      {set ret "[b][c 1 04]L[/c][/b]"}
		draw - d - md {set ret "[b][c 1 05]D[/c][/b]"}
		nc - nd - n   {set ret "[b][c 1 14]N[/c][/b]"}
	}

	return $ret
}

proc ::sherdog::add {listVar format args} {
	upvar $listVar l
	if {[llength $args] && [join $args ""] == ""} {
		return $l
	}
	return [lappend l [format $format {*}$args]]
}

proc ::sherdog::addn {listVar args} {
	upvar $listVar l
	lappend l " "
	return [add l {*}$args]
}

proc ::sherdog::tabulate {data {maxColSizes {}} {sep " | "}} {
	set sizes {}
	set table {}

	foreach line $data {
		set cols [split [regsub -all [regsub -all {\W} $sep {\\&}] $line \0] \0]

		# remove columns that have been given 0 size
		for {set i [expr {[llength $cols] - 1}]} {$i >= 0} {incr i -1} {
			if {[lindex $maxColSizes $i] == 0} {
				set cols [lreplace $cols $i $i]
			}
		}

		set i 0
		foreach col $cols {
			set size [string length $col]
			if {$i >= [llength $sizes]} {
				lappend sizes $size
			} elseif {$size > [lindex $sizes $i]} {
				set sizes [lreplace $sizes $i $i $size]
			}
			incr i
		}
		lappend table $cols
	}

	# column pruning is done, so remove all zero-width column specifiers
	while {[set i [lsearch $maxColSizes 0]] >= 0} {
		set maxColSizes [lreplace $maxColSizes $i $i]
	}

	set columnFormats {}
	set i 0
	foreach size $sizes {
		set max [lindex $maxColSizes $i]
		if {[string is digit -strict $max]} {
			lappend columnFormats "%-[expr {min($size, $max)}].${max}s"
		} else {
			lappend columnFormats "%-${size}s"
		}
		incr i
	}

	set tabulated {}

	foreach cols $table {
		lappend tabulated [format [join $columnFormats $sep] {*}$cols]
	}

	return $tabulated
}

proc ::sherdog::c {color {bgcolor ""}} {
	return "\003$color[expr {$bgcolor == "" ? "" : ",$bgcolor"}]"
}
proc ::sherdog::/c {} { return "\003" }
proc ::sherdog::b  {} { return "\002" }
proc ::sherdog::/b {} { return "\002" }
proc ::sherdog::r  {} { return "\026" }
proc ::sherdog::/r {} { return "\026" }
proc ::sherdog::u  {} { return "\037" }
proc ::sherdog::/u {} { return "\037" }

proc ::sherdog::fetch {url args} {
	http::register https 443 tls::socket
	variable HTTP_TIMEOUT

	set token ""
	if {[llength $args]} {
		set token [http::geturl "$url?[http::formatQuery {*}$args]" -timeout $HTTP_TIMEOUT]
	} else {
		set token [http::geturl $url -timeout $HTTP_TIMEOUT]
	}
	set status [http::status $token]
	set response [http::data $token]
	http::cleanup $token
	http::unregister https

	return $response
}

proc ::sherdog::findLink {html {substr "http"}} {
	set dom [dom parse -html $html]
	set doc [$dom documentElement]
	return [$doc selectNodes [subst -nocommands {string(//a[contains(@href, '$substr')][1]/@href)}]]
}

proc ::sherdog::select {doc selector {format string} {dateFormatIn "%Y-%m-%d"} {dateFormatOut "%Y-%m-%d"}} {
	set ret [string trim [$doc selectNodes "string($selector)"]]
	if {$format == "date"} {
		catch {set ret [clock format [clock scan [string trim $ret /] -format $dateFormatIn] -format $dateFormatOut]}
	}
	return $ret
}
