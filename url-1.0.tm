package require tls
package require uri
package require http

namespace eval ::url {
    namespace export get

    variable HTTP_TIMEOUT 5000
    variable HTTP_MAX_REDIRECTS 5
}

proc ::url::get {url args} {
    variable HTTP_TIMEOUT
    variable HTTP_MAX_REDIRECTS
    set response ""
    set token ""

    http::register https 443 tls::socket

    array set URI [uri::split $url]
    for {set i 0} {$i < $HTTP_MAX_REDIRECTS} {incr i} {
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
