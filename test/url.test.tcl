#!/usr/bin/env tclsh

::tcl::tm::path add [file normalize [file join [file dirname [info script]] ..]]

package require url
package require tcltest
namespace import ::tcltest::*

test url::get "should return content at URL" -body {
    url::get "https://www.google.com"
} -match glob -result "*<title>Google</title>*"

test url::get "should follow redirects" -body {
    # the following should redirect to https://www.google.com
    url::get "http://google.com"
} -match glob -result "*<title>Google</title>*"

cleanupTests
