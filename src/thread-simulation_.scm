;; Critical section used with the semaphores. action and actions will
;; be executed inside the given semaphore (that should be a mutex for
;; a critical-section) and the semaphore will be released after the
;; execution of the actions is finished. The last returned value of
;; action/actions will be returned by this macro.
(define-macro (critical-section! sem action . actions)
  (let ((result (gensym 'crit-section-result)))
    `(begin
       (sem-lock! ,sem)
       (let ((,result (begin ,action ,@actions)))
         (sem-unlock! ,sem)
         ,result))))


;; Will result in termination the currently running coroutine and
;; executing directly the specified continuation coroutine, bypassing
;; the other coroutines waiting in the coroutine queue.
(define-macro (prioritized-continuation continuation-corout)
  (define arg (gensym 'arg))
  (define c (gensym 'continuation-corout))
  `(let ((,c ,continuation-corout))
     (prioritize! ,c)
     (corout-kont-set! ,c (let ((k (corout-kont ,c)))
                           (lambda (,arg)
                             (unprioritize! ,c)
                             (if (procedure? k)
                                 (k ,arg)
                                 (continuation-return k ,arg)))))
     (terminate-corout ,c)))

(define-macro (prioritized-thunk-continuation continuation-thunk)
  `(begin
     (prioritize! (current-corout))
     (yield)
     (unprioritize! (current-corout))
     (,continuation-thunk)))



(define-macro (continue-with continuation-corout)
  `(terminate-corout ,continuation-corout))

(define-macro (continue-with-thunk! continuation-thunk)
  `(continue-with (new-corout (gensym 'corout) ,continuation-thunk)))



(define-macro (compose-thunks . thunks)
  (define (id id1 id2) `(gensym (symbol-append 'composition-of- ,id1 ,id2)))
  (define (composition thunks)
    (cond ((not (pair? thunks))
           (error (string-append "thunk composition must"
                                 "contain at least 1 thunk")))
          ((and (pair? thunks)
                (null? (cdr thunks)))
           (car thunks))
          (else
           `(lambda ()
              (,(car thunks))
              (continue-with-thunk! ,(composition (cdr thunks)))))))
  (composition thunks))

(define-macro (spawn . body)
  (let ((brother (gensym 'brother)))
    `(let ((,brother (new-corout (gensym (symbol-append
                                          (corout-id (current-corout))
                                          '-child))
                          (lambda () ,@body))))
       (spawn-brother ,brother)
       ,brother)))

(define-macro (timeout? toval . code)
  `(with-exception-catcher
    (lambda (e) (if (eq? e mailbox-timeout-exception)
                    ,toval
                    (raise e)))
    (lambda () ,@code)))

(define-macro (with-dynamic-handlers handlers . bodys)
  (let ((false (gensym 'false)))
    `(parameterize ((dynamic-handlers
                     (cons (lambda ()
                             (let ((found?
                                    ;; here the dynamic handlers *must
                                    ;; not* be used to avoid inf loop
                                    (recv use-dynamic-handlers?: #f
                                          poll-only?: (box ',false)
                                          ,@handlers)))
                               (if (eq? found? ',false)
                                   #f
                                   (box found?))))
                           (dynamic-handlers))))
       ,@bodys)))

;; poll-only? will ensure that the corout is not put to sleep if no
;; msg is matched. The *unboxed* value of poll-only? will be used to
;; return from recv...
(define-macro (recv #!key (use-dynamic-handlers? #t) (poll-only? #f)
                    #!rest pattern-list)
  (define (make-ast test-pattern eval-pattern)
    (vector test-pattern eval-pattern))
  (define (ast-test-pattern x) (vector-ref x 0))
  (define (ast-eval-pattern x) (vector-ref x 1))
  (define (pattern->ast pat)
    (if (and (list? pat) (>= (length pat) 2))
        (match pat
               ((,pattern (where ,@conds) ,@ret-val)
                (make-ast `(,pattern when: (and ,@conds) #t)
                          `(,pattern when: (and ,@conds) ,@ret-val)))
               ((,pattern ,@ret-val)
                (make-ast `(,pattern #t)
                          `(,pattern ,@ret-val)))
               (,_ (error "bad recv pattern format")))))
  (define (generate-predicate asts)
    (let ((msg (gensym 'msg)))
      `(lambda (,msg) (match ,msg
                             ,@(map ast-test-pattern asts)
                             (,(list 'unquote '_) #f)))))
  (define (generate-on-msg-found asts)
    (let ((msg (gensym 'msg)))
      `(lambda (,msg) (match ,msg
                             ,@(map ast-eval-pattern asts)
                             (,(list 'unquote '_) #f)))))
  (define (filter pred list)
    (cond
     ((not (pair? list)) '())
     ((pred (car list)) (cons (car list) (filter pred (cdr list))))
     (else (filter pred (cdr list)))))

  (define (drop lst n)
    (if (or (< n 1) (not (pair? lst)))
        lst
        (drop (cdr lst) (- n 1))))

  (define (take-right lst n)
    (let lp ((lag lst)  (lead (drop lst n)))
      (if (pair? lead)
          (lp (cdr lag) (cdr lead))
          lag)))
  (include "include/match.scm")
  ;; not sure wht to do.. otherwise that lib gets loaded 2 times
  ;;(load "src/scm-lib.scm") 

  (let* ((last-pat (take-right pattern-list 1))
         (timeout-val (and (eq? (caar last-pat) 'after)
                           (cadar last-pat)))
         (timeout-ret-val (if (eq? (caar last-pat) 'after)
                              (cddar last-pat)
                              '(raise mailbox-timeout-exception)))
         (cleaned-patterns (filter
                            (lambda (x) (match x
                                               ((after ,_ ,_) #f)
                                               (,_ #t)))
                            pattern-list))
         (asts (map pattern->ast cleaned-patterns))
         (loop    (gensym 'loop))
         (mailbox (gensym 'mailbox))
         (absolute-timeout (gensym 'absolute-timeout)))
    `(let ((,mailbox (corout-mailbox (current-corout)))
           (,absolute-timeout ,(if timeout-val
                                   `(+ (time->seconds (current-time))
                                       ,timeout-val)
                                   '+inf.0)))
       (let ,loop ()
            (cond
             ;; Normal message processing
             ((queue-find-and-remove!
               ,(generate-predicate asts)
               ,mailbox)
              => ,(generate-on-msg-found asts))

             ;; Dynamic handlers processing, loop back to continue to
             ;; wait for the messages
             ,(if use-dynamic-handlers?
                  `((find-value (lambda (pred) (pred))
                                (dynamic-handlers))
                    => (lambda (res) (unbox res) (,loop)))
                  `(#f 'i-hope-this-is-optimized...))

             ;; if no acceptable message found, sleep
             (else
              ,(cond
                (poll-only?
                 `(begin (unbox ,poll-only?)))
                ((not timeout-val)
                 `(begin (continuation-capture
                          (lambda (k)
                            (let ((corout (current-corout)))
                              (corout-kont-set! corout k)
                              (corout-set-sleeping-mode!
                               corout
                               (sleeping-on-msg))
                              (corout-scheduler))))
                         (,loop)))
                (else
                 `(let ((sleep-delta (- ,absolute-timeout
                                        (time->seconds (current-time)))))
                    (if (> sleep-delta 0)
                        (begin
                          (sleep-for sleep-delta interruptible?: #t)
                          (,loop))
                        (begin ,@timeout-ret-val)))))))))))

(define-macro (recv-only . pattern-list)
  (define (drop lst n)
    (if (or (< n 1) (not (pair? lst)))
        lst
        (drop (cdr lst) (- n 1))))

  (define (take-right lst n)
    (let lp ((lag lst)  (lead (drop lst n)))
      (if (pair? lead)
          (lp (cdr lag) (cdr lead))
          lag)))

  (define (drop-right lst n)
    (let recur ((lag lst) (lead (drop lst n)))
      (if (pair? lead)
          (cons (car lag) (recur (cdr lag) (cdr lead)))
          '())))

  (let* ((error-pattern
          `(,(list 'unquote 'msg)
            (error (to-string (show "received unexpected-message: " msg)))))
         (last-pat (car (take-right pattern-list 1)))
         (timeout-pattern (and (eq? (car last-pat) 'after)
                               last-pat)))
    ;; Must extract the timeout pattern and re-insert at the end of
    ;; the generated recv sequence
    (if timeout-pattern
        `(recv use-dynamic-handlers?: #f
               ,@(drop-right pattern-list 1)
               ,error-pattern
               ,timeout-pattern)
        `(recv use-dynamic-handlers?: #f
               ,@pattern-list
               ,error-pattern))))

(define-macro (clean-mailbox pattern)
  (let ((loop (gensym 'loop))
        (counter (gensym 'counter)))
   `(let ,loop ((,counter 0))
      (recv (,pattern (,loop (+ ,counter 1)))
            (after 0 ,counter)))))
