#! /usr/bin/env tclsh

::tcl::tm::path add [file normalize [file join [file dirname [info script]] ..]]

package require sherdog
package require tcltest
namespace import ::tcltest::*

test sherdog::query {should fetch fighter data} {
    if {[sherdog::query "ronda rousey" data err]} {
        return [expr {[llength $data] > 0}]
    }
    return 0
} 1

test sherdog::query {should return error message for failed query} {
    if {[sherdog::query "aaaaaaaaaaaaa" data err]} {
        return 0
    }
    return [expr {[string length $err] > 0}]
} 1
