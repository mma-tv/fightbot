#! /usr/bin/env tclsh

####################################################################
#
# Module: bestfightodds.tcl
# Author: makk@EFnet
# Description: bestfightodds.com event scraper
# Release Date: Oct 28, 2019
#  Last Update: Oct 29, 2019
#
####################################################################

package require tls
package require http
package require tdom

package provide bestfightodds 1.0

namespace eval bestfightodds {
    namespace export -clear import
    variable URL "https://www.bestfightodds.com"
    variable HTTP_TIMEOUT 5000
}

proc bestfightodds::parse {html} {
    set dom [dom parse -html $html]
    set doc [$dom documentElement]
    set events {}

    foreach section [$doc selectNodes {.//*[@class='table-div']}] {
        set header [$section selectNodes {.//*[@class='table-header']}]
        set event [$header selectNodes {string(.//a)}]
        if {$event eq "Future Events"} {
            continue
        }
        set date [$header selectNodes {string(.//*[@class='table-header-date'])}]
        if {$date eq "" || [catch {set date [clock scan [regsub {(?:st|nd|rd|th)$} $date ""]]}]} {
            set date [clock scan "6 months"]
        } elseif {$date < [clock scan "-1 month"]} {
            # if assuming current year puts the date more than 1 month before now, assume next year
            set date [clock scan "1 year" -base $date]
        }
        set time "6pm"
        switch -glob -nocase -- $event {
            {UFC: The Ultimate Fighter*} {set time "10pm"}
            {UFC*} {set time "10pm"}
            Bellator* {set time "8pm"}
        }
        set date [clock format [clock scan $time -base $date] -format "%Y-%m-%d %H:%M:%S" -gmt 1]

        set table [$section selectNodes {.//*[@class='odds-table']//tbody}]
        set fighter1 [$table selectNodes {.//*[@class='even']}]
        set fighter2 [$table selectNodes {.//*[@class='odd']}]
        set fights {}
        foreach f1 $fighter1 f2 $fighter2 {
            lappend fights [list\
                fighter1 [$f1 selectNodes {string(.//th)}]\
                fighter2 [$f2 selectNodes {string(.//th)}]\
                odds1 [$f1 selectNodes {string(.//*[@class='bestbet'])}]\
                odds2 [$f2 selectNodes {string(.//*[@class='bestbet'])}]\
            ]
        }
        lappend events [list event $event date $date fights $fights]
    }

    return $events
}

proc bestfightodds::import {data error} {
    variable URL
    upvar $data d
    upvar $error e
    if {[catch {set d [parse [fetch $URL]]} err]} {
        set e $err
        return false
    }
    set e ""
    return true
}

proc bestfightodds::fetch {url args} {
    variable HTTP_TIMEOUT
    set response ""
    set token ""
    set MAX_REDIRECTS 5

    http::register https 443 tls::socket

    array set URI [uri::split $url]
    for {set i 0} {$i < $MAX_REDIRECTS} {incr i} {
        if {[llength $args]} {
            set token [http::geturl "$url?[http::formatQuery {*}$args]" -timeout $HTTP_TIMEOUT]
        } else {
            set token [http::geturl $url -timeout $HTTP_TIMEOUT]
        }
        if {![string match {30[1237]} [http::ncode $token]]} {
            break
        }
        set location [lmap {k v} [set ${token}(meta)] {
            if {[string match -nocase location $k]} {set v} continue
        }]
        if {$location eq {}} {
            break
        }
        array set uri [uri::split $location]
        if {$uri(host) eq {}} {
            set uri(host) $URI(host)
        }
        # problem w/ relative versus absolute paths
        set url [uri::join {*}[array get uri]]
        http::cleanup $token
        set token ""
    }

    if {$token ne ""} {
        set response [http::data $token]
        http::cleanup $token
    }

    http::unregister https
    return $response
}
