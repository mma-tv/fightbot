#! /usr/bin/env tclsh

####################################################################
#
# Module: sherdog.tcl
# Author: makk@EFnet
# Description: Sherdog Fight Finder parser
# Release Date: October 27, 2019
#
####################################################################

package require tls
package require http
package require tdom

package provide sherdog 1.0

namespace eval sherdog {
    namespace export -clear query parse print printSummary

    variable SEARCH_BASE  "https://www.bing.com/search"
    variable SEARCH_QUERY "site:sherdog.com/fighter %s"
    variable SEARCH_LINK  "sherdog.com/fighter/"
    variable HTTP_TIMEOUT 5000
    variable CACHE_EXPIRATION 180 ;# minutes

    variable cache
}

if {[info commands putlog] == ""} {
    proc putlog {s} { puts "\[*\] $s" }
}

proc sherdog::parse {html {url ""}} {
    # hack to clean up malformed html that breaks the parser
    regsub -all {(?:/\s*)+(?=/\s*>)} $html "" html
    set dom [dom parse -html $html]
    set doc [$dom documentElement]

    set fighter [list\
        name [select $doc {//h1//*[contains(@class, 'fn')]}]\
        nickname [select $doc {//h1//*[contains(@class, 'nickname')]//*}]\
        birthDate [select $doc {//*[@itemprop='birthDate']} date]\
        height [select $doc {//*[@itemprop='height']}]\
        weight [select $doc {//*[@itemprop='weight']}]\
        weightClass [select $doc {//*[contains(@class, 'wclass')]//a}]\
        nationality [select $doc {//*[@itemprop='nationality']}]\
        association [select $doc {//*[contains(@class, 'association')]//strong}]\
        url $url\
        age ""\
    ]

    dict with fighter {
        if {$birthDate != "" && ![catch {set dt [clock scan $birthDate]}]} {
            set age [expr ([clock seconds] - $dt) / (60 * 60 * 24 * 365)]
        }
    }

    set upcoming [$doc selectNodes {//*[contains(@class, 'event-upcoming')]}]
    if {$upcoming != ""} {
        dict set fighter fights upcoming [list\
            event [select $upcoming {.//h2}]\
            date [select $upcoming {.//h4/node()} date "%B %d, %Y"]\
            location [select $upcoming {.//*[@itemprop='address']}]\
            opponent [select $upcoming {.//*[contains(@class, 'right_side')]//*[@itemprop='name']}]\
            opponentRecord\
                [regsub -all {\s+}\
                    [select $upcoming {.//*[contains(@class, 'right_side')]//*[contains(@class, 'record')]}]\
                ""]\
        ]
    }

    foreach {id type} [list pro "Pro" proEx "Pro Exhibition" amateur "Amateur"] {
        set fights [$doc selectNodes [subst -nocommands {
            //*[contains(@class, 'fight_history')][.//h2[text() = 'Fight History - $type']]//tr[position() > 1]
        }]]

        set totalFights [llength $fights]
        if {$totalFights == 0} {
            continue
        }

        set history {}
        set wins 0
        set losses 0
        set draws 0
        set other 0

        foreach row $fights {
            set result [string tolower [select $row {td[1]}]]

            lappend history [list\
                result $result\
                opponent [select $row {td[2]}]\
                event [select $row {td[3]//a}]\
                date [select $row {td[3]//*[contains(@class, 'sub_line')]} date "%b / %d / %Y"]\
                method [select $row {td[4]/node()}]\
                ref [select $row {td[4]//*[contains(@class, 'sub_line')]}]\
                round [select $row {td[5]}]\
                time [select $row {td[6]}]\
            ]

            switch -- $result {
                win { incr wins }
                loss { incr losses }
                draw { incr draws }
                default { incr other }
            }
        }

        set record [list wins $wins losses $losses draws $draws other $other]

        dict set fighter fights $id record $record
        dict set fighter fights $id history [lreverse $history]
    }

    $dom delete

    return $fighter
}

proc sherdog::query {query response err {mode -verbose} args} {
    variable SEARCH_BASE
    variable SEARCH_QUERY
    variable SEARCH_LINK

    upvar $response res
    upvar $err e
    set res {}
    set e ""

    set url [cache link $query]
    if {$url == ""} {
        putlog "Searching for sherdog link matching '$query'"
        set searchResults [fetch $SEARCH_BASE q [format $SEARCH_QUERY $query]]
        set url [getFirstSearchResult $searchResults $SEARCH_LINK]
        regsub {\#.*} $url "" url
        if {$url == ""} {
            set e "No match for '$query' in the Sherdog Fight Finder."
            return false
        }
        cache link $query $url
    }

    set data [cache data $url]
    if {$data == ""} {
        putlog "Fetching sherdog content at $url"
        set html [fetch $url]
        if {[catch {set data [parse $html $url]}]} {
            set e "Failed to parse Sherdog content at $url for '$query' query. Notify the bot developer."
            return false
        }
        cache data $url $data
    }

    switch -- $mode {
        -s - -short - -summary {
            set res [printSummary $data {*}$args]
        }
        default {
            set res [print $data {*}$args]
        }
    }

    return true
}

proc sherdog::print {fighter {maxColSizes {*}}} {
    set output {}

    dict with fighter {
        add output "[b][u]%s[/u][/b]" [expr {$nickname == "" ? $name : "$name \"$nickname\""}]
        add output "  [b]AGE[/b]: %s (%s)" $age $birthDate
        add output "  [b]HEIGHT[/b]: %s" $height
        add output "  [b]WEIGHT[/b]: %s (%s)" $weight $weightClass
        add output "  [b]NATIONALITY[/b]: %s" $nationality
        add output "  [b]ASSOCIATION[/b]: %s" $association
    }

    foreach {id title} {amateur "AMATEUR" proEx "PRO EXHIBITION" pro "PRO"} {
        if {[dict exists $fighter fights $id history]} {
            dict with fighter fights $id record {
                addn output "[b]%s FIGHTS[/b]: %s" $title\
                    [formatRecord $wins $losses $draws $other true]
            }

            set i 0
            set history [dict get $fighter fights $id history]
            set maxCountSpace [string length [llength $history]]
            set results {}

            foreach fight $history {
                dict with fight {
                    add results "%${maxCountSpace}d. %s" [incr i] [fightInfo $fight]
                }
            }

            if {[llength $maxColSizes]} {
                lappend output {*}[tabulate $results $maxColSizes]
            } else {
                lappend output {*}$results
            }
        }
    }

    if {[dict exists $fighter fights upcoming]} {
        dict with fighter fights upcoming {
            addn output "[b]NEXT OPPONENT[/b] (%s away): [b]%s[/b] (%s) | %s | %s | %s"\
                [relativeTime $date {-s}] $opponent $opponentRecord $date $event $location
        }
    }

    if {$url != ""} {
        addn output "Source: [b]%s[/b]" [dict get $fighter url]
    }

    return $output
}

proc sherdog::printSummary {fighter {limit 0} {maxColSizes {*}} {showNextOpponent true}} {
    set output {}
    set record "AMATEUR"
    set hasProFights [dict exists $fighter fights pro]

    if {$hasProFights} {
        dict with fighter fights pro record {
            set record [formatRecord $wins $losses $draws $other]
        }

        set widget ""

        foreach fight [lrange [dict get $fighter fights pro history] end-19 end] {
            dict with fight {
                append widget [formatResult $result]
            }
        }

        append record " $widget"
    }

    dict with fighter {
        add output "[b]%s[/b]%s%s %s%s %s" $name\
            [expr {$nickname == "" ? "" : " \"$nickname\""}]\
            [countryCode $nationality { [%s]}] $record\
            [expr {$age == "" ? "" : " ${age}yo"}] $url
    }

    if {$hasProFights && $limit > 0} {
        set results {}
        set list [lrange [lreverse [dict get $fighter fights pro history]] 0 $limit-1]

        foreach fight $list {
            dict with fight {
                add results [fightInfo $fight]
            }
        }

        if {[llength $maxColSizes]} {
            lappend output {*}[tabulate $results $maxColSizes]
        } else {
            lappend output {*}$results
        }
    }

    if {$showNextOpponent && [dict exists $fighter fights upcoming]} {
        dict with fighter fights upcoming {
            add output "Next opponent in %s: [b]%s[/b] (%s) on %s at %s"\
                [relativeTime $date] $opponent $opponentRecord\
                [collapse [clock format [clock scan $date] -format "%b %e"]] $event
        }
    }

    return $output
}

proc sherdog::fightInfo {fight} {
    dict with fight {
        return [format "%s[b]%s[/b] | [b]%s[/b] | %s | %s | %s | R%s %s | %s"\
            [formatResult $result "\u258c"] [string toupper [string index $result 0]]\
            $opponent $date $event $method $round $time $ref]
    }
}

proc sherdog::countryCode {nationality {fmt "%s"}} {
    variable countries
    set c [string tolower [string trim $nationality]]
    if {$c != ""} {
        foreach expr [list $c "${c}*" "*${c}" "*${c}*"] {
            set code [lindex [array get countries $expr] 1]
            if {$code != ""} {
                return [format $fmt $code]
            }
        }
        putlog "sherdog::countryCode() NO MATCH FOR $nationality"
    }
    return ""
}

proc sherdog::relativeTime {date {useShortFormat ""}} {
    set days [expr ([clock scan $date] - [clock scan 0]) / 60 / 60 / 24]
    if {$days >= 60} {
        set tm [expr $days / 30]
        return [expr {$useShortFormat == "" ? [plural $tm month] : "${tm}m"}]
    } elseif {$days >= 14} {
        set tm [expr $days / 7]
        return [expr {$useShortFormat == "" ? [plural $tm week] : "${tm}w"}]
    }
    return [expr {$useShortFormat == "" ? [plural $days day] : "${days}d"}]
}

proc sherdog::formatResult {result {c "\u25cf"}} {
    set ret $result

    switch -nocase -- $result {
        win  - w      {set ret "[c 03]$c[/c]"}
        loss - l      {set ret "[c 04]$c[/c]"}
        draw - d - md {set ret "[c 01]$c[/c]"}
        nc   - n - nd {set ret "[c 15]$c[/c]"}
    }

    return $ret
}

proc sherdog::formatRecord {{wins 0} {losses 0} {draws 0} {other 0} {showPct false}} {
    set record [list $wins $losses $draws]
    if {$other} {
        lappend record $other
    }

    if {$showPct} {
        set total 0
        foreach val $record {
            incr total $val
        }

        set recordPct {}
        foreach val $record {
            lappend recordPct [expr round(($val / double($total)) * 100)]
        }

        return [format "%s (%s%%)" [join $record "-"] [join $recordPct "%-"]]
    }

    return [join $record "-"]
}

proc sherdog::add {listVar format args} {
    upvar $listVar l
    if {[llength $args] && [join $args ""] == ""} {
        return $l
    }
    return [lappend l [format $format {*}$args]]
}

proc sherdog::addn {listVar args} {
    upvar $listVar l
    lappend l " "
    return [add l {*}$args]
}

proc sherdog::tabulate {data {maxColSizes {}} {sep " | "}} {
    set sizes {}
    set table {}

    foreach line $data {
        set cols [splitString $line $sep]

        # remove columns that have been given 0 size
        for {set i [expr {[llength $cols] - 1}]} {$i >= 0} {incr i -1} {
            if {[lindex $maxColSizes $i] == 0} {
                set cols [lreplace $cols $i $i]
            }
        }

        set i 0
        foreach col $cols {
            set size [string length $col]
            if {$i >= [llength $sizes]} {
                lappend sizes $size
            } elseif {$size > [lindex $sizes $i]} {
                set sizes [lreplace $sizes $i $i $size]
            }
            incr i
        }
        lappend table $cols
    }

    # column pruning is done, so remove all zero-width column specifiers
    while {[set i [lsearch $maxColSizes 0]] >= 0} {
        set maxColSizes [lreplace $maxColSizes $i $i]
    }

    set columnFormats {}
    set i 0
    foreach size $sizes {
        set max [lindex $maxColSizes $i]
        if {[string is digit -strict $max]} {
            lappend columnFormats "%-[expr min($size, $max)].${max}s"
        } else {
            lappend columnFormats "%-${size}s"
        }
        incr i
    }

    set tabulated {}

    foreach cols $table {
        set formatted {}
        set formattedCols [format [join $columnFormats $sep] {*}$cols]
        foreach col [splitString $formattedCols $sep] {
            lappend formatted [closeDanglingCtrlCodes $col]
        }
        lappend tabulated [join $formatted $sep]
    }

    return $tabulated
}

proc sherdog::fetch {url args} {
    variable HTTP_TIMEOUT
    set response ""
    set token ""
    set MAX_REDIRECTS 5

    http::register https 443 tls::socket

    array set URI [uri::split $url]
    for {set i 0} {$i < $MAX_REDIRECTS} {incr i} {
        if {[llength $args]} {
            set token [http::geturl "$url?[http::formatQuery {*}$args]" -timeout $HTTP_TIMEOUT]
        } else {
            set token [http::geturl $url -timeout $HTTP_TIMEOUT]
        }
        if {![string match {30[1237]} [http::ncode $token]]} {
            break
        }
        set location [lmap {k v} [set ${token}(meta)] {
            if {[string match -nocase location $k]} {set v} continue
        }]
        if {$location eq {}} {
            break
        }
        array set uri [uri::split $location]
        if {$uri(host) eq {}} {
            set uri(host) $URI(host)
        }
        # problem w/ relative versus absolute paths
        set url [uri::join {*}[array get uri]]
        http::cleanup $token
        set token ""
    }

    if {$token ne ""} {
        set response [http::data $token]
        http::cleanup $token
    }

    http::unregister https
    return $response
}

proc sherdog::getFirstSearchResult {html {substr "http"}} {
    set dom [dom parse -html $html]
    set doc [$dom documentElement]
    set link [$doc selectNodes [subst -nocommands {string(//h2//a[contains(@href, '$substr')][1]/@href)}]]
    $dom delete
    return $link
}

proc sherdog::select {doc selector {format string} {dateFormatIn "%Y-%m-%d"} {dateFormatOut "%Y-%m-%d"}} {
    set ret [string trim [$doc selectNodes "string($selector)"]]
    switch -- $format {
        string {
            set ret [collapse $ret]
        }
        date {
            catch {set ret [clock format [clock scan [string trim $ret /] -format $dateFormatIn] -format $dateFormatOut]}
        }
    }
    return $ret
}

proc sherdog::cache {store key args} {
    variable cache
    variable CACHE_EXPIRATION
    set now [clock seconds]
    set k [string tolower $key]

    if {[llength $args]} {
        set cache($store,$k) [list $now [lindex $args 0]]
    } elseif {[info exists cache($store,$k)]} {
        foreach {timestamp data} $cache($store,$k) {
            set minutesElapsed [expr ($now - $timestamp) / 60]
            if {[expr $minutesElapsed <= $CACHE_EXPIRATION]} {
                return $data
            }
        }
        array unset cache "$store,$k"
    }
    return ""
}

proc sherdog::pruneCache {} {
    variable cache
    variable CACHE_EXPIRATION

    set now [clock seconds]
    foreach key [array names cache] {
        set minutesElapsed [lindex $cache($key) 0]
        if {[expr ($now - $minutesElapsed) / 60] > $CACHE_EXPIRATION} {
            array unset cache $key
        }
    }
}

proc sherdog::emptyCache {} {
    variable cache
    array unset cache
}

proc sherdog::splitString {str substr} {
    return [split [string map [list $substr \uffff] $str] \uffff]
}

proc closeDanglingCtrlCodes {str} {
    set s $str
    set matches {}
    foreach c {\002 \003 \026 \037} {
        if {[expr [regexp -all -indices $c $str i] & 1]} {
            lappend matches [lindex $i 0]
        }
    }
    foreach c [lsort -decreasing $matches] {
        append s [string index $str $c]
    }
    return $s
}

proc sherdog::collapse {str} {
    regsub -all {\s{2,}} [string trim $str] " " collapsed
    return $collapsed
}

proc sherdog::plural {num unit {suffix "s"}} {
    return [expr {$num == 1 ? "$num $unit" : "$num ${unit}$suffix"}]
}

proc sherdog::c {color {bgcolor ""}} {
    return "\003$color[expr {$bgcolor == "" ? "" : ",$bgcolor"}]"
}
proc sherdog::/c {} { return "\003" }
proc sherdog::b  {} { return "\002" }
proc sherdog::/b {} { return "\002" }
proc sherdog::r  {} { return "\026" }
proc sherdog::/r {} { return "\026" }
proc sherdog::u  {} { return "\037" }
proc sherdog::/u {} { return "\037" }

array set sherdog::countries {
    {afghanistan} AFG
    {aland islands} ALA
    {albania} ALB
    {algeria} DZA
    {american samoa} ASM
    {andorra} AND
    {angola} AGO
    {anguilla} AIA
    {antarctica} ATA
    {antigua and barbuda} ATG
    {argentina} ARG
    {armenia} ARM
    {aruba} ABW
    {australia} AUS
    {austria} AUT
    {azerbaijan} AZE
    {bahamas} BHS
    {bahrain} BHR
    {bangladesh} BGD
    {barbados} BRB
    {belarus} BLR
    {belgium} BEL
    {belize} BLZ
    {benin} BEN
    {bermuda} BMU
    {bhutan} BTN
    {bolivia} BOL
    {bonaire, sint eustatius and saba} BES
    {bosnia and herzegovina} BIH
    {botswana} BWA
    {bouvet island} BVT
    {brazil} BRA
    {british indian ocean territory} IOT
    {brunei darussalam} BRN
    {bulgaria} BGR
    {burkina faso} BFA
    {burundi} BDI
    {cabo verde} CPV
    {cambodia} KHM
    {cameroon} CMR
    {canada} CAN
    {cayman islands} CYM
    {central african republic} CAF
    {chad} TCD
    {chile} CHL
    {china} CHN
    {christmas island} CXR
    {cocos (keeling) islands} CCK
    {colombia} COL
    {comoros} COM
    {congo} COG
    {cook islands} COK
    {costa rica} CRI
    {croatia} HRV
    {cuba} CUB
    {curacao} CUW
    {cyprus} CYP
    {czech republic} CZE
    {czechia} CZE
    {czechoslovakia} CZE
    {côte d'ivoire} CIV
    {denmark} DNK
    {djibouti} DJI
    {dominica} DMA
    {dominican republic} DOM
    {ecuador} ECU
    {egypt} EGY
    {el salvador} SLV
    {england} GBR
    {equatorial guinea} GNQ
    {eritrea} ERI
    {estonia} EST
    {eswatini} SWZ
    {ethiopia} ETH
    {falkland islands (malvinas)} FLK
    {faroe islands} FRO
    {fiji} FJI
    {finland} FIN
    {france} FRA
    {french guiana} GUF
    {french polynesia} PYF
    {french southern territories} ATF
    {gabon} GAB
    {gambia} GMB
    {georgia} GEO
    {germany} DEU
    {ghana} GHA
    {gibraltar} GIB
    {great britain} GBR
    {greece} GRC
    {greenland} GRL
    {grenada} GRD
    {guadeloupe} GLP
    {guam} GUM
    {guatemala} GTM
    {guernsey} GGY
    {guinea} GIN
    {guinea-bissau} GNB
    {guyana} GUY
    {haiti} HTI
    {heard island and mcdonald islands} HMD
    {holland} NLD
    {holy see} VAT
    {honduras} HND
    {hong kong} HKG
    {hungary} HUN
    {iceland} ISL
    {india} IND
    {indonesia} IDN
    {iraq} IRQ
    {ireland} IRL
    {islamic republic of iran} IRN
    {isle of man} IMN
    {israel} ISR
    {italy} ITA
    {jamaica} JAM
    {japan} JPN
    {jersey} JEY
    {jordan} JOR
    {kazakhstan} KAZ
    {kenya} KEN
    {kiribati} KIR
    {korea} KOR
    {kuwait} KWT
    {kyrgyzstan} KGZ
    {lao} LAO
    {latvia} LVA
    {lebanon} LBN
    {lesotho} LSO
    {liberia} LBR
    {libya} LBY
    {liechtenstein} LIE
    {lithuania} LTU
    {luxembourg} LUX
    {macao} MAC
    {madagascar} MDG
    {malawi} MWI
    {malaysia} MYS
    {maldives} MDV
    {mali} MLI
    {malta} MLT
    {marshall islands} MHL
    {martinique} MTQ
    {mauritania} MRT
    {mauritius} MUS
    {mayotte} MYT
    {mexico} MEX
    {micronesia} FSM
    {moldova} MDA
    {monaco} MCO
    {mongolia} MNG
    {montenegro} MNE
    {montserrat} MSR
    {morocco} MAR
    {mozambique} MOZ
    {myanmar} MMR
    {namibia} NAM
    {nauru} NRU
    {nepal} NPL
    {netherlands} NLD
    {new caledonia} NCL
    {new zealand} NZL
    {nicaragua} NIC
    {niger} NER
    {nigeria} NGA
    {niue} NIU
    {norfolk island} NFK
    {north korea} PRK
    {north macedonia} MKD
    {northern ireland} GBR
    {northern mariana islands} MNP
    {norway} NOR
    {oman} OMN
    {pakistan} PAK
    {palau} PLW
    {palestine} PSE
    {panama} PAN
    {papua new guinea} PNG
    {paraguay} PRY
    {peru} PER
    {philippines} PHL
    {pitcairn} PCN
    {poland} POL
    {portugal} PRT
    {puerto rico} PRI
    {qatar} QAT
    {romania} ROU
    {russian federation} RUS
    {rwanda} RWA
    {réunion} REU
    {saint-barthélemy} BLM
    {saint helena} SHN
    {saint kitts and nevis} KNA
    {saint lucia} LCA
    {saint martin} MAF
    {saint pierre and miquelon} SPM
    {saint vincent and the grenadines} VCT
    {samoa} WSM
    {san marino} SMR
    {sao tome and principe} STP
    {saudi arabia} SAU
    {scotland} GBR
    {senegal} SEN
    {serbia} SRB
    {seychelles} SYC
    {sierra leone} SLE
    {singapore} SGP
    {sint maarten} SXM
    {slovakia} SVK
    {slovenia} SVN
    {solomon islands} SLB
    {somalia} SOM
    {south africa} ZAF
    {south georgia and the south sandwich islands} SGS
    {south korea} KOR
    {south sudan} SSD
    {spain} ESP
    {sri lanka} LKA
    {sudan} SDN
    {suriname} SUR
    {svalbard and jan mayen} SJM
    {sweden} SWE
    {switzerland} CHE
    {syrian arab republic} SYR
    {taiwan} TWN
    {tajikistan} TJK
    {tanzania} TZA
    {thailand} THA
    {timor-leste} TLS
    {togo} TGO
    {tokelau} TKL
    {tonga} TON
    {trinidad and tobago} TTO
    {tunisia} TUN
    {turkey} TUR
    {turkmenistan} TKM
    {turks and caicos islands} TCA
    {tuvalu} TUV
    {uganda} UGA
    {ukraine} UKR
    {united arab emirates} ARE
    {united kingdom} GBR
    {united states of america} USA
    {uruguay} URY
    {uzbekistan} UZB
    {vanuatu} VUT
    {venezuela} VEN
    {viet nam} VNM
    {vietnam} VNM
    {virgin islands} VIR
    {wallis and futuna} WLF
    {western sahara} ESH
    {yemen} YEM
    {zambia} ZMB
    {zimbabwe} ZWE
}

proc sherdog::test {filename args} {
    set fp [open $filename r]
    set data [read $fp]
    close $fp

    foreach line [print [parse $data] {*}$args] {
        puts $line
    }
}
