Fight Bot
=========

MMA/Boxing fight logger and polling script for Eggdrop bots


Requirements
------------

  - Eggdrop 1.6.16+
  - TCL 8.5+
  - Tcllib (for **uri** module)
  - SQLite 3.6.19+


Installation
------------

  1. Install [Eggdrop] 1.6.16+, [TCL] 8.5+, and [Tcllib].
     * Tcllib can usually be installed via most package managers, but if you need to install it manually for the local user, follow the miscellaneous [instructions below](#tcllib).
  2. Install [SQLite] with TCL bindings enabled.
     * Download the [SQLite tarball with TCL bindings][sqlite-tarball]
     * Extract and build the TCL sqlite module (typically in the "tea" directory)
        * Example: `tar -zxvf sqlite*.gz && cd sqlite*/tea && ./configure && make`
     * Create a symlink in the *eggdrop* directory to wherever you installed the .so shared object file from the previous step:
        * Example:  `ln -s libsqlite3.7.11.so tclsqlite3.so`
  3. Copy **fights.tcl** and **util.tcl** to the eggdrop *scripts* directory.
  4. Copy **fights.sql** to the *eggdrop* directory.
  5. Add this line to your eggdrop's config file:  `source scripts/fights.tcl`


Miscellaneous
-------------

### Installing TCLLIB manually under a local user

  1. Download and extract [tcllib].
  2. Install with:

     ``./installer.tcl -no-apps -no-html -no-nroff -no-examples -pkg-path ~/tcllib``

     * This will install tcllib in your home directory under the directory *tcllib/*.
  3. If you wish to remove everything except the "uri" module, type:

     ``cd ~/tcllib && find * -maxdepth 0 -type d -not -name uri -exec rm -rf {} \;``

  4. Set your TCLLIBPATH to ~/tcllib in your .bashrc or .bash_profile file.
     * Example: `export TCLLIBPATH=~/tcllib`
  5. Log out and log back in (or source your .bashrc file again)


Configuration
-------------

  * Give a channel the "fights" flag to let it listen for poll commands.
  
    ``.chanset #mychan +fights``
    
  * Give a **trusted** user the "P" flag to make that person a poll administrator.
  
    ``.chattr trustydave P|fP #mychan``


Common Usage Examples
---------------------

  * To add and populate an event:
  
  ```
  .addevent UFC 220: Miocic vs. Ngannou; 2018-01-20 10pm
  .addfight Stipe Miocic vs. Francis Ngannou
  .addfight Daniel Cormier vs. Volkan Oezdemir
  ```
  
  * To list upcoming events: `.events`
  * To select the first event in the list: `.event 1`
  * To start polling the channel for picks on the 2nd fight: `.poll 2`
  * To stop polling the channel and lock in the picks: `.stop`
  * To announce that FighterB defeated FighterA: `.saywinner 2` or `.saywinner b`
  
  Message the bot with `.help` for a full list of commands.


[eggdrop]:        http://www.eggheads.org/downloads/
[tcl]:            http://www.tcl.tk/software/tcltk/download.html
[tcllib]:         http://www.tcl.tk/software/tcllib/
[sqlite]:         http://sqlite.org/download.html
[sqlite-tarball]: http://sqlite.org/sqlite-autoconf-3071100.tar.gz
