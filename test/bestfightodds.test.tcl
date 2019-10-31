#!/usr/bin/env tclsh

::tcl::tm::path add [file normalize [file join [file dirname [info script]] ..]]

package require bestfightodds
package require tcltest
namespace import ::tcltest::*

test bestfightodds::import "should return parsed fighter data" -body {
    if {[bestfightodds::import data err]} {
        dict get [lindex $data 0] date
    }
} -match regexp -result {^\d{4}-\d\d-\d\d}

cleanupTests
