#!/usr/bin/env tclsh

variable cwd [file dirname [info script]]
source [file join $cwd eggdrop-stubs.tcl]
::tcl::tm::path add [file normalize [file join $cwd ..]]

package require tags
package require tcltest
namespace import ::tcltest::*

proc setup {} {
  cleanup
  ::tags::init "tags.test.db"

  ::tags::db eval {
    INSERT INTO tags (date, nick, userhost, tag, message) VALUES
      ('2018-10-22 01:02:03', 'makk', 'k1@foo.bar.com', '1st', 'first message'),
      ('2019-01-13 01:02:03', 'Rect', 'k1@foo.bar.com', '2nd', 'second message'),
      ('2019-02-22 01:02:03', 'mbp', 'k1@foo.bar.com', 'how', 'how is this happening'),
      ('2019-03-22 01:02:03', 'makk', 'k1@foo.bar.com', NULL, 'unpossible'),
      ('2019-04-22 01:02:03', 'john', 'k1@foo.bar.com', 'ufc', 'the only way to ufc'),
      ('2019-05-22 01:02:03', 'jack', 'k1@foo.bar.com', 'conor', 'conor sucks'),
      ('2019-06-22 01:02:03', 'jack', 'k1@foo.bar.com', 'wut', 'what did you say?'),
      ('2019-06-22 01:02:03', 'jack', 'k1@foo.bar.com', 'wut2', 'what did you say?'),
      ('2019-09-22 01:02:03', 'mbp', 'k1@foo.bar.com', 'dum', 'dun be dum'),
      ('2019-10-22 01:02:03', 'ganj', 'k1@foo.bar.com', 'mmk', 'if you say so')
  }
}

proc cleanup {} {
  catch {::tags::db close}
  catch {exec rm -f tags.test.db}
}

proc globNoCase {expected actual} {
  return [string match -nocase $expected $actual]
}
customMatch globNoCase globNoCase

test tags::init "should create empty database" -setup setup -body {
  file exists "tags.test.db"
} -result 1

test tags::addTag "should add tag" -body {
  ::tags::addTag makk k1@foo.bar.com * * {.+foo bar baz}
  ::tags::db eval {SELECT date, nick, userhost, tag, message FROM tags WHERE tag = 'foo'}
} -match globNoCase -result {* makk k1@foo.bar.com foo {bar baz}} -output {*added*} -cleanup setup

test tags::addTag "should not add duplicate tags" -body {
  ::tags::addTag makk k1@foo.bar.com * * {.+ufc whatever}
} -result 1 -match glob -output {*already exists*}

test tags::addTag "should add tags with no name" -body {
  ::tags::addTag makk k1@foo.bar.com * * {.+ noname message}
  ::tags::db exists {SELECT 1 FROM tags WHERE message = 'noname message'}
} -result 1 -match globNoCase -output {*added*}

test tags::removeTag "should remove tags" -body {
  ::tags::removeTag makk k1@foo.bar.com * * {.-dum}
  ::tags::db exists {SELECT 1 FROM tags WHERE tag = 'dum'}
} -result 0 -match globNoCase -output {*deleted*}

test tags::removeTag "should NOT remove tags from non-matching hosts" -body {
  ::tags::removeTag makk non@matching.host.com * * {.-wut}
  ::tags::db exists {SELECT 1 FROM tags WHERE tag = 'wut'}
} -result 1 -match globNoCase -output {*permission*}

test tags::removeTag "should remove tags from non-matching hosts if bot owner" -body {
  ::tags::removeTag makk non@matching.host.com makk-matchattr * {.-wut2}
  ::tags::db exists {SELECT 1 FROM tags WHERE tag = 'wut2'}
} -result 0 -match globNoCase -output {*deleted*}

test tags::findTag "should find explicit tags" -body {
  ::tags::findTag * * * * {.#ufc}
} -result 1 -match glob -output {*the only way to ufc*}

test tags::findTag "should support verbose output" -body {
  ::tags::findTag * * * * {..#ufc}
} -result 1 -match glob -output {*john*k1*the only way to ufc*}

test tags::findTag "should search for tags" -body {
  ::tags::findTag * * * * {.# conor}
} -result 1 -match glob -output {*sucks*}

test tags::findTag "should return random tags" -body {
  ::tags::findTag * * * * {.#}
  ::tags::findTag * * * * {.#}
} -result 1 -match glob -output "*#*\n*#*"

test tags::findTag "should return usage help when no args" -body {
  ::tags::findTag * * * * {..#}
} -result 1 -match globNoCase -output {*usage*}

cleanup
cleanupTests
