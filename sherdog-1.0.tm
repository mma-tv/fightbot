####################################################################
#
# Module: sherdog.tm
# Author: makk@EFnet
# Description: Sherdog Fight Finder parser
#
####################################################################

::tcl::tm::path add [file dirname [info script]]

package require tdom
package require util::fetch
package require util::ctrlcodes
package require util::tabulate

namespace eval ::sherdog {
    namespace export query parse print printSummary
    namespace import ::util::tabulate
    namespace import ::util::ctrlcodes::*

    variable SEARCH_BASE  "https://www.bing.com/search"
    variable SEARCH_QUERY "site:sherdog.com/fighter %s"
    variable SEARCH_LINK  "sherdog.com/fighter/"
    variable USE_CACHE    true
    variable CACHE_EXPIRATION 90 ;# minutes

    variable cache
}

if {[info commands putlog] eq ""} {
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
        if {$birthDate ne "" && ![catch {set dt [clock scan $birthDate]}]} {
            set age [expr ([clock seconds] - $dt) / (60 * 60 * 24 * 365)]
        }
    }

    set upcoming [$doc selectNodes {//*[contains(@class, 'event-upcoming')]}]
    if {$upcoming ne ""} {
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
    if {$url eq ""} {
        putlog "Searching for sherdog link matching '$query'"
        set searchResults [util::fetch $SEARCH_BASE q [format $SEARCH_QUERY $query]]
        set url [getFirstSearchResult $searchResults $SEARCH_LINK]
        regsub {\#.*} $url "" url
        if {$url eq ""} {
            set e "No match for '$query' in the Sherdog Fight Finder."
            return false
        }
        cache link $query $url
    }

    set data [cache data $url]
    if {$data eq ""} {
        putlog "Fetching sherdog content at $url"
        set html [util::fetch $url]
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
        add output "[b][u]%s[/u][/b]" [expr {$nickname eq "" ? $name : "$name \"$nickname\""}]
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
            addn output "[b]NEXT OPPONENT[/b] %s: [b]%s[/b] (%s) | %s | %s | %s"\
                [relativeTime $date] $opponent $opponentRecord $date $event $location
        }
    }

    if {$url ne ""} {
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
        append record " [graphicalRecord $fighter 20]"
    }

    dict with fighter {
        add output "[b]%s[/b]%s%s %s%s %s" $name\
            [expr {$nickname eq "" ? "" : " \"$nickname\""}]\
            [countryCode $nationality { [%s]}] $record\
            [expr {$age eq "" ? "" : " ${age}yo"}] $url
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
            add output "Next opponent %s: [b]%s[/b] (%s) on %s at %s"\
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
            $opponent [clock format [clock scan $date] -format {%b %d %Y}] $event\
            $method $round $time $ref]
    }
}

proc sherdog::graphicalRecord {fighter {limit 20} {prefix ""}} {
    set widget ""

    if {[dict exists $fighter fights pro history]} {
        append widget $prefix

        foreach fight [lrange [dict get $fighter fights pro history] end-[expr $limit - 1] end] {
            dict with fight {
                append widget [formatResult $result]
            }
        }
    }

    return $widget
}

proc sherdog::countryCode {nationality {fmt "%s"}} {
    variable countries
    set c [string tolower [string trim $nationality]]
    if {$c ne ""} {
        foreach expr [list $c "${c}*" "*${c}" "*${c}*"] {
            set code [lindex [array get countries $expr] 1]
            if {$code ne ""} {
                return [format $fmt $code]
            }
        }
        putlog "sherdog::countryCode() NO MATCH FOR $nationality"
    }
    return ""
}

proc sherdog::relativeTime {date {prefix "in "} {useShortFormat false}} {
    set days [expr ([clock scan $date] - [clock scan 0]) / 60 / 60 / 24]
    set time $days
    set unit "day"
    if {$days == 0} {
        return "TODAY"
    } elseif {$days >= 60} {
        set time [expr $days / 30]
        set unit "month"
    } elseif {$days >= 14} {
        set time [expr $days / 7]
        set unit "week"
    }
    if {$useShortFormat == true} {
        return "$prefix$time[string index $unit 0]"
    }
    if {$time > 0} {
        return "$prefix$time $unit[expr {$time == 1 ? "" : "s"}]"
    }
    return ""
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
    if {[llength $args] && [join $args ""] eq ""} {
        return $l
    }
    return [lappend l [format $format {*}$args]]
}

proc sherdog::addn {listVar args} {
    upvar $listVar l
    lappend l " "
    return [add l {*}$args]
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
    variable USE_CACHE

    if {!$USE_CACHE} {
        return ""
    }

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

proc sherdog::pruneCache {args} {
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

proc sherdog::clearCache {args} {
    variable cache
    array unset cache
}

proc sherdog::collapse {str} {
    regsub -all {\s{2,}} [string trim $str] " " collapsed
    return $collapsed
}

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
