#!/usr/bin/env tclsh

::tcl::tm::path add [file normalize [file join [file dirname [info script]] ..]]

package require url
package require sherdog
package require tcltest
namespace import ::tcltest::*

test sherdog::parse "should parse fighter data" -setup {
    set html [url::get "https://www.sherdog.com/fighter/Ronda-Rousey-73073"]
} -body {
    set fighter [sherdog::parse $html]
    dict get $fighter name
} -result "Ronda Rousey"

test sherdog::query "should print fighter data" -body {
    if {[sherdog::query "ronda rousey" data err]} {
        return $data
    }
} -match glob -result "*Rowdy*"

test sherdog::query "should return error message for failed query" -body {
    if {![sherdog::query "aaaaaaaaaaaaaaa" data err]} {
        return $err
    }
} -match glob -result "?*"

cleanupTests
