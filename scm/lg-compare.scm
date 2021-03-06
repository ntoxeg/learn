;
; lg-compare.scm -- Compare parses from two different LG dictionaries.
;
; -----------------------------------------------------------------
; Overview:
; ---------
; The general goal of the code here is to obtain the accuracy, recall
; and other statistics of a test-dictionary, compared to a gold-standard
; dictionary. This is done by creating a comparison function that can
; parse sentences with both dictionaries, and then verifies the presence
; or absence of links between words.
;
(use-modules (srfi srfi-1))
(use-modules (ice-9 optargs)) ; for define*-public

(use-modules (opencog) (opencog exec) (opencog nlp))
(use-modules (opencog nlp lg-dict) (opencog nlp lg-parse))


(define*-public (make-lg-comparator en-dict other-dict #:key
     (INCLUDE-MISSING #f)
     (VERBOSE #f)
)
"
  lg-compare GOLD-DICT OTHER-DICT - Return a sentence comparison function.

  GOLD-DICT and OTHER-DICT should be the two LgDictNodes to compare.
  The code makes weak assumptions that GOLD-DICT is the reference or
  \"golden\" lexis to compare to, so that any differences found in
  OTHER-DICT are blamed on OTHER-DICT.

  This returns a comparison function.  To use it, pass one or more
  sentence strings to it; it will compare the resulting parses.
  When finished, pass it `#f`, and it will print a summary report.

  Example usage:
     (define compare (make-lg-comparator
        (LgDictNode \"en\") (LgDictNode \"micro-fuzz\")))
     (compare \"I saw her face\")
     (compare \"I swooned to the floor\")
     (compare #f)

  By default, this does not test sentences that have words that are
  not in the test dictionary.  Over-ride this by supplying the optional
  argument INCLUDE-MISSING.
"
	(let ((verbose VERBOSE)

		; -------------------
		; Stats we are keeping
			(total-sentences 0)
			(total-compares 0)
			(incomplete-dict 0)
			(temp-cnt 0)
			(bad-sentences 0)
			(total-words 0)
			(total-links 0)
			(length-miscompares 0)
			(word-miscompares 0)
			(link-count-miscompares 0)
			(link-correct 0)
			(link-excess 0)
			(link-deficit 0)

			(present-primary 0)
			(present-secondary 0)
			(present-punct 0)
			(present-other 0)
			(missing-primary 0)
			(missing-secondary 0)
			(missing-punct 0)
			(missing-other 0)

			(missing-link-types '())
			(missing-words (make-atom-set))
			(vocab-words (make-atom-set))
		)

		; ----------------------------------------
		; LG English link-type classes
		(define primary-links (list "S" "O" "MV" "SI" "CV"))
		(define secondary-links (list "A" "AN" "B" "C" "D" "E" "EA" "G" "J" "M" "MX" "R"))
		(define punct-links (list "X"))

		; ----------------------------------------
		; Misc utilities

		; Get the word of the word instance, i.e. the WordNode.
		(define (get-word-of-winst WRD)
			(gdr (car (cog-incoming-by-type WRD 'ReferenceLink))))

		; Get the index of the word instance, i.e. the NumberNode.
		(define (get-index-of-winst WRD)
			(gdr (car (cog-incoming-by-type WRD 'WordSequenceLink))))

		; ------
		; Place the word-instance list into sequential order.
		; i.e. left-to-right order, as the word appear in a sentence.
		(define (sort-word-inst-list LST)
			(sort LST
				(lambda (wa wb)
					(define (get-num wi)
						(string->number (cog-name (get-index-of-winst wi))))
					(< (get-num wa) (get-num wb)))))

		; ------
		; Return a sorted list of the paired word-instances that this
		; word links to. To avoid double-counting, this returns only the
		; links connecting to the right. To avoid spurious RIGHT-WALL
		; miscompares, all instances of RIGHT-WALL are stripped out.
		(define (get-linked-winst WIN)
			(sort-word-inst-list
				(map gdr
					; Accept only those ListLinks that are bonfide word-links
					(filter
						(lambda (lili)
							(and
								; Is the first word (left word) ours?
								(equal? (gar lili) WIN)

								; Is the second word (right word) the RIGHT-WALL?
								(not (equal? (cog-name
									(get-word-of-winst (gdr lili))) "###RIGHT-WALL###"))

								; Are any of the possible EvaluationLink's
								; an LG relation? If so, we are happy.
								(any
									(lambda (evlnk)
										(equal? 'LinkGrammarRelationshipNode
											(cog-type (gar evlnk))))
									(cog-incoming-by-type lili 'EvaluationLink))
							))
						(cog-incoming-by-type WIN 'ListLink)))))

		; ------
		; Return the name of a link connecting lwin (left word
		; instance) and rwin (right word instance). There must actually
		; be a link connecting them, else bad things happen.
		(define (get-link-name lwin rwin)
			(gar (car (filter
				(lambda (evl)
					(equal? (cog-type (gar evl)) 'LinkGrammarRelationshipNode))
				(cog-incoming-by-type (ListLink lwin rwin)
					'EvaluationLink)))))

		; Return the string-name of a link. Truncate link subtypes.
		(define (get-link-str-name lwin rwin)
			(string-trim-right
				(cog-name (get-link-name lwin rwin))
				(char-set-adjoin char-set:lower-case #\*)))

		; ------
		; Increment count for a missing link type putting the count
		; in an association list, so that we can print all muffed
		; types at the end.
		(define (incr-missing-link-type-count link-name)
			(define cnt (assoc-ref missing-link-types link-name))
			(if (not cnt) (set! cnt 0))
			(set! missing-link-types
				(assoc-set! missing-link-types link-name (+ 1 cnt))))

		(define (incr-missing-link-count lwin rwin)
			(define link-name (get-link-str-name lwin rwin))
			(if VERBOSE
				(format #t "Missing link: ~A <-- ~A --> ~A\n"
					(cog-name (get-word-of-winst lwin))
					link-name
					(cog-name (get-word-of-winst rwin))))
			(cond
				((any (lambda (lt) (equal? lt link-name)) primary-links)
					(set! missing-primary (+ 1 missing-primary)))
				((any (lambda (lt) (equal? lt link-name)) secondary-links)
					(set! missing-secondary (+ 1 missing-secondary)))
				((any (lambda (lt) (equal? lt link-name)) punct-links)
					(set! missing-punct (+ 1 missing-punct)))
				(else (set! missing-other (+ 1 missing-other))))
			(incr-missing-link-type-count link-name))

		(define (incr-present-link-count lwin rwin)
			(define link-name (get-link-str-name lwin rwin))
			(if VERBOSE
				(format #t "Have link: ~A <-- ~A --> ~A\n"
					(cog-name (get-word-of-winst lwin))
					link-name
					(cog-name (get-word-of-winst rwin))))
			(cond
				((any (lambda (lt) (equal? lt link-name)) primary-links)
					(set! present-primary (+ 1 present-primary)))
				((any (lambda (lt) (equal? lt link-name)) secondary-links)
					(set! present-secondary (+ 1 present-secondary)))
				((any (lambda (lt) (equal? lt link-name)) punct-links)
					(set! present-punct (+ 1 present-punct)))
				(else (set! present-other (+ 1 present-other))))
		)
		; ----------------------------------------
		; Comparison functions

		; Return the number of words in the sentence that are not in
		; the test dictionary. This also adds them to the mising-words
		; set.
		(define (num-missing-words winli dict)
			(fold
				(lambda (win cnt)
					(define wrd (get-word-of-winst win))
					(if (< 0.5 (cog-tv-mean
							(cog-evaluate! (LgHaveDictEntry wrd dict))))
						cnt
						(begin
							(missing-words wrd)
							(+ cnt 1))))
				0 winli))

		; Return #t if the sentence contains missing words.
		(define (has-missing-words winli)
			(if (< 0 (num-missing-words winli other-dict))
				(begin
					(set! incomplete-dict (+ 1 incomplete-dict))
					#t)
				#f))

		; ---
		; The length of the sentences should match.
		(define (compare-lengths en-sorted other-sorted)
			(define ewlilen (length en-sorted))
			(define owlilen (length other-sorted))

			; Both should usually have the same length. Note, however,
			; that LG English will split "I'm" -> "I 'm" i.e. one word
			; into two, and that many/most test dictionaries do NOT do
			; this.  This leads to instant miscompares... Count total
			; words ONLY if lengh-compare passes.
			(if (equal? ewlilen owlilen)
				(set! total-words (+ total-words ewlilen))
				(begin
					(format #t "Length miscompare: ~A vs ~A\n" ewlilen owlilen)
					(set! length-miscompares (+ 1 length-miscompares))))

			; Return #t is the lengths are good!
			(equal? ewlilen owlilen))

		; ---
		; The words should compare. We are not currently comparing the
		; sequence; doing so would be complicated, and I don't see how
		; the sequences could ever mis-compare...
		(define (compare-words ewinst owinst)
			(define ewrd (get-word-of-winst ewinst))
			(define owrd (get-word-of-winst owinst))
			(vocab-words ewrd)
			(if (not (equal? ewrd owrd))
				(begin
					(if verbose
						(format #t "Word miscompare at ~A: ~A vs ~A\n"
							(get-index-of-winst ewinst) ewrd owrd))
					(set! word-miscompares (+ 1 word-miscompares)))))

		; ---
		; Compare links. For the given words, find the words that link to
		; the right. Verify that there are the same number of them, and
		; that they have the same targets.
		; ewin should be a word-instance from the EN side
		; owin should be the OTHER word instance.
		(define (compare-links ewin owin)
			(define ewrd (get-word-of-winst ewin))

			; elinked and olinked are lists of word instances
			; that are linked to the right of the current word.
			(define elinked (get-linked-winst ewin))
			(define olinked (get-linked-winst owin))

			; Obtain sets of the linked words (not the word-instances)
			(define ewords (map get-word-of-winst elinked))
			(define owords (map get-word-of-winst olinked))

			; A set of words in ewords that are not in owords
			; These correspond to missing links.
			(define miss-w (lset-difference equal? ewords owords))

			; A set of words in ewords that are also in owords
			; These correspond to correct links.
			(define have-w (lset-intersection equal? ewords owords))

			; A set of words in owords that are not in ewords
			; These correspond to extra, unexpected links.
			(define extra-w (lset-difference equal? owords ewords))

			; Keep only word-instances that are in the word-set.
			(define (trim-wili wili wrd-set)
				(filter
					(lambda (wi)
						(any
							(lambda (wrd) (equal? (get-word-of-winst wi) wrd))
							wrd-set))
					wili))

			; Missing linked word-instances...
			(define missing-wi (trim-wili elinked miss-w))
			(define present-wi (trim-wili elinked have-w))
			(define extra-wi   (trim-wili olinked extra-w))

			(define n-missing (length missing-wi))
			(define n-present (length present-wi))
			(define n-extra   (length extra-wi))

			(set! link-deficit (+ link-deficit n-missing))
			(set! link-correct (+ link-correct n-present))
			(set! link-excess  (+ link-excess  n-extra))

			; A count of how many LG-English generated.
			(set! total-links (+ total-links (length elinked)))

			(if (or (< 0 n-missing) (< 0 n-extra))
				(begin
					(if verbose
						(format #t "Miscompare right-links: ~A missing, ~A extra for ~A"
							n-missing n-extra ewrd))
					(set! link-count-miscompares (+ 1 link-count-miscompares))))

			; Create a histogram of missing link types.
			(for-each
				(lambda (misw) (incr-missing-link-count ewin misw))
				missing-wi)

			; And also the ones that we have.
			(for-each
				(lambda (havw) (incr-present-link-count ewin havw))
				present-wi)
		)

		; -------------------
		; The main comparison function
		(define (do-compare SENT)
			; Get a parse, one for each dictionary.
			(define en-sent (cog-execute!
				(LgParseMinimal (PhraseNode SENT) en-dict (NumberNode 1))))
			(define other-sent (cog-execute!
				(LgParseMinimal (PhraseNode SENT) other-dict (NumberNode 1))))

			; Since only one parse, we expect only one...
			(define en-parse (gar (car
				(cog-incoming-by-type en-sent 'ParseLink))))
			(define other-parse (gar (car
				(cog-incoming-by-type other-sent 'ParseLink))))

			; Get a list of the words in each parse.
			(define other-word-inst-list
				(map gar (cog-incoming-by-type other-parse 'WordInstanceLink)))

			(define left-wall (WordNode "###LEFT-WALL###"))
			(define right-wall (WordNode "###RIGHT-WALL###"))

			; Get the list of words in the standard dict.
			; XXX Temp hack. Currently, the test dicts are missing LEFT-WALL
			; and RIGHT-WALL and so we filter these out manually. This
			; should be made more elegant.
			(define en-word-inst-list
				(filter
					(lambda (winst)
						(define wrd (get-word-of-winst winst))
						(and
							(not (equal? wrd left-wall))
							(not (equal? wrd right-wall))))
					(map gar (cog-incoming-by-type en-parse 'WordInstanceLink))))

			; Sort into sequential order. Pain-in-the-neck. Hardly worth it.
			(define en-sorted (sort-word-inst-list en-word-inst-list))
			(define other-sorted (sort-word-inst-list other-word-inst-list))

			(define dict-has-missing-words (has-missing-words other-sorted))

			(set! total-sentences (+ total-sentences 1))

			(if dict-has-missing-words
				(format #t "Dictionary is missing words in: \"~A\"\n" SENT))

			; Don't do anything more, if the dict is missing words in the
			; sentence. ... unless the INCLUDE-MISSING flag is set.
			; Don't do anything if there as a sentence-length miscompare.
			; Such miscompares pointlessly garbage up the stats.
			(if (and
					(or (not dict-has-missing-words) INCLUDE-MISSING)
					(compare-lengths en-sorted other-sorted))
				(begin
					(set! total-compares (+ total-compares 1))
					(set! temp-cnt link-count-miscompares)

					; Compare words and links
					(for-each
						(lambda (ewrd owrd)
							(compare-words ewrd owrd)
							(compare-links ewrd owrd)
						)
						en-sorted other-sorted)

					(if (not (equal? temp-cnt link-count-miscompares))
						(set! bad-sentences (+ 1 bad-sentences)))
					(format #t "Finish compare of sentence ~A/~A: \"~A\"\n"
						total-compares total-sentences SENT)
				))
		)

		; -------------------
		; The main comparison function
		(define (do-compare-gc SENT)
			(define (kill typ)
				(for-each cog-extract-recursive (cog-get-atoms typ)))
			(catch 'C++-EXCEPTION
				(lambda () (do-compare SENT))
				(lambda (key . args) #f))

			; Cleanup most stuff, but not WordNodes, because
			; they have to be saved in the "missing words" list.
			; Sadly, cannot use push-pop atomspace as a result.
			; This makes an almost unmeasureable difference in
			; performance and mem usage... so is not really needed.
			(kill 'NumberNode)
			(kill 'WordInstanceNode)
			(kill 'SentenceNode)
			(kill 'PhraseNode)
			(kill 'ParseNode)
			(kill 'LinkGrammarRelationshipNode)
			(kill 'LgHaveDictEntry)
		)

		; -------------------
		(define (report-stats)
			; Compute link precision and recall.
			; total-links is the number of links that LG English found.
			(define link-expected-positives (exact->inexact total-links))

			; The links that were exactly right.
			(define link-true-positives link-correct)

			; The links we should not have seen...
			(define link-false-positives link-excess)

			; The links that were just-pain missing.
			(define link-false-negatives link-deficit)

			(define link-recall (/ link-true-positives link-expected-positives))
			(define link-precision (/ link-true-positives
				(+ link-true-positives link-false-positives)))
			(define link-f1 (/ (* 2.0 link-recall link-precision)
				(+ link-recall link-precision)))

			; Compute the recall of important link types.
			(define primary-total
				(+ missing-primary present-primary))
			(define secondary-total
				(+ missing-secondary present-secondary))
			(define punct-total
				(+ missing-punct present-punct))
			(define other-total
				(+ missing-other present-other))

			(define primary-recall
				(/ present-primary primary-total))
			(define secondary-recall
				(/ present-secondary secondary-total))
			(define punct-recall
				(if (equal? 0 punct-total) (inf)
					(/ present-punct punct-total)))
			(define other-recall
				(/ present-other other-total))

			; Put missing link counts into sorted order.
			(define sorted-missing-links
				(sort missing-link-types
					(lambda (ia ib) (> (cdr ia) (cdr ib)))))

			(newline)
			(newline)
			(format #t
				"Examined ~A sentences; ~A had words not in dictionary (~6F %).\n"
				total-sentences incomplete-dict
				(/ (* 100.0 incomplete-dict) total-sentences))
			(format #t
				"Finished comparing ~A parses; ~A parsed differently (~6F %).\n"
				total-compares bad-sentences
				(/ (* 100.0 bad-sentences) total-compares))
			(format #t
				"Found ~A word instances, vocab= ~A words; expect to find ~A links\n"
				total-words (length (vocab-words #f)) total-links)
			(format #t "Dictionary was missing ~A words\n"
				(length (missing-words #f)))
			(format #t "Found ~A length-miscompares\n" length-miscompares)
			(format #t "Found ~A word-miscompares\n" word-miscompares)
			(format #t
				"Found ~A words w/diffs in #links: ~A fewer and ~A extra links\n"
				link-count-miscompares
				link-deficit link-excess)

			(format #t "Link precision=~6F recall=~6F F1=~6F\n"
				link-precision link-recall link-f1)
			(newline)

			(format #t "Primary     link-type recall=~6F tot=~A ~A\n"
				primary-recall primary-total primary-links)
			(format #t "Secondary   link-type recall=~6F tot=~A ~A\n"
				secondary-recall secondary-total secondary-links)
			(format #t "Punctuation link-type recall=~6F tot=~A ~A\n"
				punct-recall punct-total punct-links)
			(format #t "Other       link-type recall=~6F tot=~A (all other types)\n"
				other-recall other-total)

			(newline)
			(format #t "Counts of missing link-types: ~A\n\n"
				sorted-missing-links)
			(format #t "Missing words: ~A\n\n"
				(map cog-name (missing-words #f)))
		)

		; -------------------
		; The main comparison function
		(lambda (SENT)
			(if (not SENT)
				(report-stats)
				(do-compare-gc SENT)))
	)
)
