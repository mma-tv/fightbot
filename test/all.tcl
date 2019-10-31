#!/usr/bin/env tclsh

package require tcltest
::tcltest::configure -testdir [file dirname [file normalize [info script]]] -file *.test.tcl
::tcltest::runAllTests
