Fight Bot
=========

MMA/Boxing fight logger and polling script for Eggdrop bots


Requirements
------------

  - Eggdrop 1.6.16+
  - TCL 8.5+
  - SQLite 3.6.19+


Setup
-----

  1. Install SQLite
     * Download the [tarball](http://sqlite.org/sqlite-autoconf-3071100.tar.gz) with TCL bindings from the [SQLite download page](http://sqlite.org/download.html)
     * Extract and build the TCL sqlite module (typically in the "tea" directory)
        * Example: `tar -zxvf sqlite*.gz && cd sqlite*/tea && ./configure && make`
     * Create a symlink in the **eggdrop directory** to wherever you installed the .so shared object file from the previous step:
        * Example:  `ln -s libsqlite3.7.11.so tclsqlite3.so`
  2. Copy fights.tcl and util.tcl to eggdrop scripts directory
  3. Copy fights.sql to eggdrop directory
