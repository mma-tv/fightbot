namespace eval ::bot {
    namespace export registerCleanup
}

proc ::bot::cleanup {nsRef db type} {
    foreach bind [binds "*${nsRef}::*"] {
        foreach {type flags command {} handler} $bind {
            catch {unbind $type $flags $command $handler}
        }
    }
    catch {$db close}
    namespace delete $nsRef
    return
}

proc ::bot::registerCleanup {nsRef db} {
    return [bind evnt - prerehash [list ::bot::cleanup $nsRef $db]]
}
