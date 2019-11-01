#!/usr/bin/env tclsh

::tcl::tm::path add [file normalize [file join [file dirname [info script]] ..]]

package require formatter
package require tcltest
namespace import ::tcltest::*

test formatter::tabulate "should align columns of rows of delimited strings" -setup {
    set rows {{aaaa | bb | ccccc} {d | eeee | fff}}
} -body {
    formatter::tabulate $rows
} -result {{aaaa | bb   | ccccc} {d    | eeee | fff  }}

test formatter::tabulate "should allow arbitrary delimiter" -setup {
    set rows {{aaaa - bb - ccccc} {d - eeee - fff}}
} -body {
    formatter::tabulate $rows " - "
} -result {{aaaa - bb   - ccccc} {d    - eeee - fff  }}

test formatter::tabulate "should allow max column widths" -setup {
    set rows {{aaaa | bb | ccccc} {d | eeee | fff}}
} -body {
    formatter::tabulate $rows " | " {2 * 1}
} -result {{aa | bb   | c} {d  | eeee | f}}

test formatter::tabulate "should remove columns that have 0 max width" -setup {
    set rows {{aaaa | bb | ccccc} {d | eeee | fff}}
} -body {
    formatter::tabulate $rows " | " {* 0}
} -result {{aaaa | ccccc} {d    | fff  }}

cleanupTests
