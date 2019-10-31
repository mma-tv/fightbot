#!/usr/bin/env tclsh

::tcl::tm::path add [file normalize [file join [file dirname [info script]] ..]]

package require formatter
package require tcltest
namespace import ::tcltest::*

test formatter::tabulate "should align columns of rows of delimited strings" -setup {
    set rows [list {aaaa | bb | ccccc} {dd | eeee | fff}]
} -body {
    formatter::tabulate $rows
} -result [list {aaaa | bb   | ccccc} {dd   | eeee | fff  }]

test formatter::tabulate "should allow arbitrary delimiter" -setup {
    set rows [list {aaaa - bb - ccccc} {dd - eeee - fff}]
} -body {
    formatter::tabulate $rows " - "
} -result [list {aaaa - bb   - ccccc} {dd   - eeee - fff  }]

cleanupTests
