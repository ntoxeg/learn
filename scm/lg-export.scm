;
; Export-to-Link-Grammar module.
; This is distinct from (opencog nlp learn) because it depends on `dbi`
; which not everyone has installed, and so loading this module might
; trigger an error.
;
(define-module (opencog nlp lg-export))

; Just one file for now.
(load "lg-export/export-disjuncts.scm")
