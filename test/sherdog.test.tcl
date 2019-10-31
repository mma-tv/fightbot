#!/usr/bin/env tclsh

::tcl::tm::path add [file normalize [file join [file dirname [info script]] ..]]

package require url
package require sherdog
package require tcltest
namespace import ::tcltest::*

test sherdog::query "should parse fighter data" -setup {
    set html [url::get "https://www.sherdog.com/fighter/Ronda-Rousey-73073"]
} -body {
    set fighter [sherdog::parse $html]
    dict get $fighter name
} -result "Ronda Rousey"

test sherdog::query "should print fighter data" -body {
    set ret [sherdog::query "ronda rousey" data err]
    expr {$ret && [llength $data]}
} -result 1

test sherdog::query "should return error message for failed query" -body {
    set ret [sherdog::query "aaaaaaaaaaaaa" data err]
    expr {!$ret && $err ne ""}
} -result 1

cleanupTests
