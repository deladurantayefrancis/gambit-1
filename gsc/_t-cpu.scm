;;============================================================================

;;; File: "_t-cpu.scm"

;;; Copyright (c) 2011-2017 by Marc Feeley, All Rights Reserved.

(include "generic.scm")
(include "_utils.scm")

(include-adt "_envadt.scm")
(include-adt "_gvmadt.scm")
(include-adt "_ptreeadt.scm")
(include-adt "_sourceadt.scm")
(include-adt "_x86#.scm")
(include-adt "_asm#.scm")
(include-adt "_codegen#.scm")

;;-----------------------------------------------------------------------------

;; Some functions for generating and executing machine code.

;; The function u8vector->procedure converts a u8vector containing a
;; sequence of bytes into a Scheme procedure that can be called.
;; The code in the u8vector must obey the C calling conventions of
;; the host architecture.

(define (u8vector->procedure code fixups)
 (machine-code-block->procedure
  (u8vector->machine-code-block code fixups)))

(define (u8vector->machine-code-block code fixups)
 (let* ((len (u8vector-length code))
        (mcb (##make-machine-code-block len)))
   (let loop ((i (fx- len 1)))
     (if (fx>= i 0)
         (begin
           (##machine-code-block-set! mcb i (u8vector-ref code i))
           (loop (fx- i 1)))
         (apply-fixups mcb fixups)))))

;; Add mcb's base address to every label that needs to be fixed up.
;; Currently assumes 32 bit width.
(define (apply-fixups mcb fixups)
  (let ((base-addr (##foreign-address mcb)))
    (let loop ((fixups fixups))
      (if (null? fixups)
          mcb
          (let* ((pos (asm-label-pos (caar fixups)))
                 (size (quotient (cdar fixups) 8))
                 (n (+ base-addr (machine-code-block-int-ref mcb pos size))))
            (machine-code-block-int-set! mcb pos size n)
            (loop (cdr fixups)))))))

(define (machine-code-block-int-ref mcb start size)
  (let loop ((n 0) (i (- size 1)))
    (if (>= i 0)
        (loop (+ (* n 256) (##machine-code-block-ref mcb (+ start i)))
              (- i 1))
        n)))

(define (machine-code-block-int-set! mcb start size n)
  (let loop ((n n) (i 0))
    (if (< i size)
        (begin
          (##machine-code-block-set! mcb (+ start i) (modulo n 256))
          (loop (quotient n 256) (+ i 1))))))

(define (machine-code-block->procedure mcb)
  (lambda (#!optional (arg1 0) (arg2 0) (arg3 0))
    (##machine-code-block-exec mcb arg1 arg2 arg3)))

(define (time-cgc cgc)
  (let* ((code (asm-assemble-to-u8vector cgc))
         (fixups (codegen-context-fixup-list cgc))
         (procedure (u8vector->procedure code fixups)))
    (display "time-cgc: \n\n\n\n")
    (asm-display-listing cgc (current-error-port) #f)
    (pp (time (procedure)))))

;;;----------------------------------------------------------------------------
;;
;; "CPU" back-end that targets hardware processors.

;; Initialization/finalization of back-end.

(define (cpu-setup
         target-arch
         file-extensions
         max-nb-gvm-regs
         default-nb-gvm-regs
         default-nb-arg-regs
         semantics-changing-options
         semantics-preserving-options)

  (define common-semantics-changing-options
    '())

  (define common-semantics-preserving-options
    '((asm symbol)))

  (let ((targ
         (make-target 12
                      target-arch
                      file-extensions
                      (append semantics-changing-options
                              common-semantics-changing-options)
                      (append semantics-preserving-options
                              common-semantics-preserving-options)
                      0)))

    (define (begin! sem-changing-opts
                    sem-preserving-opts
                    info-port)

      (target-dump-set!
       targ
       (lambda (procs output c-intf module-descr unique-name)
         (cpu-dump targ
                   procs
                   output
                   c-intf
                   module-descr
                   unique-name
                   sem-changing-opts
                   sem-preserving-opts)))

      (target-link-info-set!
       targ
       (lambda (file)
         (cpu-link-info targ file)))

      (target-link-set!
       targ
       (lambda (extension? inputs output warnings?)
         (cpu-link targ extension? inputs output warnings?)))

      (target-prim-info-set! targ cpu-prim-info)

      (target-frame-constraints-set!
       targ
       (make-frame-constraints
        cpu-frame-reserve
        cpu-frame-alignment))

      (target-proc-result-set!
       targ
       (make-reg 1))

      (target-task-return-set!
       targ
       (make-reg 0))

      (target-switch-testable?-set!
       targ
       (lambda (obj)
         (cpu-switch-testable? targ obj)))

      (target-eq-testable?-set!
       targ
       (lambda (obj)
         (cpu-eq-testable? targ obj)))

      (target-object-type-set!
       targ
       (lambda (obj)
         (cpu-object-type targ obj)))

      (cpu-set-nb-regs targ sem-changing-opts max-nb-gvm-regs)

      #f)

    (define (end!)
      #f)

    (target-begin!-set! targ begin!)
    (target-end!-set! targ end!)
    (target-add targ)))

(cpu-setup 'x86-32 '((".s" . X86-32))  5 5 3 '() '())
(cpu-setup 'x86-64 '((".s" . X86-64)) 13 5 3 '() '())
(cpu-setup 'arm    '((".s" . ARM))    13 5 3 '() '())

;;;----------------------------------------------------------------------------

;; ***** REGISTERS AVAILABLE

;; The registers available in the virtual machine default to
;; cpu-default-nb-gvm-regs and cpu-default-nb-arg-regs but can be
;; changed with the gsc options -nb-gvm-regs and -nb-arg-regs.
;;
;; nb-gvm-regs = total number of registers available
;; nb-arg-regs = maximum number of arguments passed in registers

(define cpu-default-nb-gvm-regs 5)
(define cpu-default-nb-arg-regs 3)

(define (cpu-set-nb-regs targ sem-changing-opts max-nb-gvm-regs)
  (let ((nb-gvm-regs
         (get-option sem-changing-opts
                     'nb-gvm-regs
                     cpu-default-nb-gvm-regs))
        (nb-arg-regs
         (get-option sem-changing-opts
                     'nb-arg-regs
                     cpu-default-nb-arg-regs)))

    (if (not (and (<= 3 nb-gvm-regs)
                  (<= nb-gvm-regs max-nb-gvm-regs)))
        (compiler-error
         (string-append "-nb-gvm-regs option must be between 3 and "
                        (number->string max-nb-gvm-regs))))

    (if (not (and (<= 1 nb-arg-regs)
                  (<= nb-arg-regs (- nb-gvm-regs 2))))
        (compiler-error
         (string-append "-nb-arg-regs option must be between 1 and "
                        (number->string (- nb-gvm-regs 2)))))

    (target-nb-regs-set! targ nb-gvm-regs)
    (target-nb-arg-regs-set! targ nb-arg-regs)))

;;;----------------------------------------------------------------------------

;; The frame constraints are defined by the parameters
;; cpu-frame-reserve and cpu-frame-alignment.

(define cpu-frame-reserve 0) ;; no extra slots reserved
(define cpu-frame-alignment 1) ;; no alignment constraint

;;;----------------------------------------------------------------------------

;; ***** PROCEDURE CALLING CONVENTION

(define (cpu-label-info targ nb-params closed?)
  ((target-label-info targ) nb-params closed?))

(define (cpu-jump-info targ nb-args)
  ((target-jump-info targ) nb-args))

;;;----------------------------------------------------------------------------

;; ***** PRIMITIVE PROCEDURE DATABASE

(define cpu-prim-proc-table
  (let ((t (make-prim-proc-table)))
    (for-each
     (lambda (x) (prim-proc-add! t x))
     '())
    t))

(define (cpu-prim-info name)
  (prim-proc-info cpu-prim-proc-table name))

(define (cpu-get-prim-info name)
  (let ((proc (cpu-prim-info (string->canonical-symbol name))))
    (if proc
        proc
        (compiler-internal-error
         "cpu-get-prim-info, unknown primitive:" name))))

;;;----------------------------------------------------------------------------

;; ***** OBJECT PROPERTIES

(define (cpu-switch-testable? targ obj)
  ;;(pretty-print (list 'cpu-switch-testable? 'targ obj))
  #f);;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (cpu-eq-testable? targ obj)
  ;;(pretty-print (list 'cpu-eq-testable? 'targ obj))
  #f);;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (cpu-object-type targ obj)
  ;;(pretty-print (list 'cpu-object-type 'targ obj))
  'bignum);;;;;;;;;;;;;;;;;;;;;;;;;

;;;----------------------------------------------------------------------------

;; ***** LINKING

(define (cpu-link-info file)
  (pretty-print (list 'cpu-link-info file))
  #f)

(define (cpu-link extension? inputs output warnings?)
  (pretty-print (list 'cpu-link extension? inputs output warnings?))
  #f)

;;;----------------------------------------------------------------------------

;; ***** INLINING OF PRIMITIVES

(define (cpu-inlinable name)
  (let ((prim (cpu-get-prim-info name)))
    (proc-obj-inlinable?-set! prim (lambda (env) #t))))

(define (cpu-testable name)
  (let ((prim (cpu-get-prim-info name)))
    (proc-obj-testable?-set! prim (lambda (env) #t))))

(define (cpu-jump-inlinable name)
  (let ((prim (cpu-get-prim-info name)))
    (proc-obj-jump-inlinable?-set! prim (lambda (env) #t))))

(cpu-inlinable "##fx+")
(cpu-inlinable "##fx-")

(cpu-testable "##fx<")

;;;----------------------------------------------------------------------------

;; ***** DUMPING OF A COMPILATION MODULE

(define (cpu-dump targ
                  procs
                  output
                  c-intf
                  module-descr
                  unique-name
                  sem-changing-options
                  sem-preserving-options)

  (pretty-print (list 'cpu-dump
                      (target-name targ)
                      (map proc-obj-name procs)
                      output
                      unique-name))

  (let ((port (current-output-port)))
      (virtual.dump-gvm procs port)
      (dispatch-target targ procs output c-intf module-descr unique-name sem-changing-options sem-preserving-options)
  #f))

;;;----------------------------------------------------------------------------

;; ***** Dispatching

(define (dispatch-target targ
                         procs
                         output
                         c-intf
                         module-descr
                         unique-name
                         sem-changing-options
                         sem-preserving-options)
  (let* ((arch (target-name targ))
          (handler (case arch
                  ('x86-32  x86-backend)
                  ('x86-64  x86-64-backend)
                  ('arm     armv8-backend)
                  (else (compiler-internal-error "dispatch-target, unsupported target: " arch))))
          (cgc (make-codegen-context)))

    (codegen-context-listing-format-set! cgc 'gnu)

    (handler
      targ procs output c-intf
      module-descr unique-name
      sem-changing-options sem-preserving-options
      cgc)

    (time-cgc cgc)))

;;;----------------------------------------------------------------------------

;; ***** Abstract machine (AM)
;;  We define an abstract instruction set which we program against for most of
;;  the backend. Most of the code is moving data between registers and the stack
;;  and jumping to locations, so it reduces the repetion between native backends
;;  (x86, x64, ARM, Risc V, etc.).
;;
;;
;;  To reduce the overhead the following high-level instructions are defined in
;;  the native assembly:
;;    apply-primitive cgc primName ...
;;    set-narg/check-narg cgc narg
;;    check-poll cgc ...
;;    make-opnd cgc ...
;;
;;  Default methods are given if possible
;;
;;
;;  In case the native architecture is load-store, set load-store-only to true.
;;  The am-mov instruction acts like both load and store.
;;
;;
;;  The following non-branching instructions are required:
;;    am-label: Place label
;;    am-ret  : Exit program
;;    am-mov  : Move value between 2 registers/memory/immediate
;;    am-cmp  : Compare 2 operands. Sets flag
;;    am-add  : (Add imm/reg to register). If load-store-only, mem can be used as opn
;;    am-sub  : (Add imm/reg to register). If load-store-only, mem can be used as opn
;;    ...
;;
;;
;;  The following branching instructions are required:
;;    am-jmp      : Jump to location
;;    am-jmplink  : Jump and store location. (Branch and link)
;;    am-je       : Jump if equal
;;    am-jne      : Jump if not equal
;;    am-jg       : Jump if greater (signed)
;;    am-jng      : Jump if not greater (signed)
;;    am-jge      : Jump if greater or equal (signed)
;;    am-jnge     : Jump if not greater or equal (signed)
;;    am-jgu      : Jump if greater (unsigned)
;;    am-jngu     : Jump if not greater (unsigned)
;;    am-jgeu     : Jump if greater or equal (unsigned)
;;    am-jngeu    : Jump if not greater or equal (unsigned)
;;    execute-cond: NOT IMPLEMENTED. Execute code given only if condition is true.
;;                  This may be useful with conditionnal instructions in ARM
;;                  On other arch, it still provides a nice abstraction for entering small branches
;;
;;  Note: Branching instructions on overflow/carry/sign/parity/etc. are not needed.
;;
;;
;;  The following instructions have a default implementation:
;;    am-lea  : Load address of memory location
;;    ...
;;
;;
;;  The following non-instructions function have to be defined
;;    int-opnd: Create int immediate object   (See int-opnd)
;;    lbl-opnd: Create label immediate object (See x86-imm-lbl)
;;    mem-opnd: Create memory location object (See x86-mem)
;;
;;
;;  The operand objects have to follow the x86 operands objects formats.
;;  This is because the default implementations may assume they follow the format. (Ex: lea)
;;
;;  To add new native backend, see x64-setup function

;; ***** AM: Caracteristics

(define word-width 64)
(define word-width-bytes 8)
(define load-store-only #f)

;; ***** AM: Operands

(define int-opnd #f)
(define lbl-opnd #f)
(define mem-opnd #f)

;; ***** AM: Instructions
;; ***** AM: Instructions: Misc

(define am-lbl #f)
(define am-ret #f)
(define am-mov #f)
(define am-lea default-lea)

(define am-check-narg default-check-narg)
(define am-set-narg   default-set-narg)
(define am-check-poll default-check-poll) ;; todo: Find better name than check-poll
(define make-opnd     default-make-opnd)

;; ***** AM: Instructions: Arithmetic

(define am-cmp #f)
(define am-add #f)
(define am-sub #f)

;; ***** AM: Instructions: Branch

;; Jump
(define am-jmp   #f)
;; Call (Branch and link). Has default implementation
(define am-jmplink default-jmplink)

;; Equal
(define am-je    #f)
(define am-jne   #f)
;; Signed
(define am-jg    #f) ;; Greater. Equivalent to: less or equal
(define am-jng   #f) ;; Not greater
(define am-jge   #f) ;; Greater or equal. Equivalent to: not less
(define am-jnge  #f) ;; Not greater or equal. Equivalent to: less
;; Unsigned
(define am-jgu   #f) ;; Greater
(define am-jngu  #f) ;; Not greater
(define am-jgeu  #f) ;; Greater or equal
(define am-jngeu #f) ;; Not greater or equal

;; ***** AM: Data

(define am-db #f)
(define am-dw #f)
(define am-dd #f)
(define am-dq #f)

;; ***** AM: Default implementations

(define (default-lea cgc reg opnd)
  (define (mem-opnd? x) (and (vector? x) (fx= (vector-length x) 4)))
  (define (mem-opnd-offset x) (vector-ref x 0))
  (define (mem-opnd-reg1 x) (vector-ref x 1))
  (define (mem-opnd-reg2 x) (vector-ref x 2))
  (define (mem-opnd-scale x) (vector-ref x 3))

  ;; No need for reg2 and scale
  (if (not (mem-opnd? opnd))
    (compiler-internal-error "am-lea: opnd isn't mem location"))
  (if (mem-opnd-reg2 opnd)
    (compiler-internal-error "am-lea: default implementation doesn't support reg2 and scale"))
  (am-mov cgc reg (int-opnd (mem-opnd-offset opnd)))
  (if (mem-opnd-reg1 opnd)
    (am-add cgc reg (mem-opnd-reg1 opnd))))

(define (default-jmplink cgc opnd)
  (am-mov cgc (get-register 0) opnd)
  (am-jmp opnd))

(define (default-check-narg cgc narg)
  (debug "default-check-narg: " narg "\n")
  (load-mem-if-necessary cgc (thread-descriptor narg-offset)
    (lambda (opnd)
      (am-cmp cgc opnd (int-opnd narg))
      (am-jne cgc WRONG_NARGS_LBL))))
  ; (if load-store-only
  ;   (begin
  ;     (am-mov cgc (get-extra-register 0) (thread-descriptor narg-offset))
  ;     )
  ;   (begin
  ;     (am-cmp cgc (thread-descriptor narg-offset) (int-opnd narg))
  ;     (am-jne cgc WRONG_NARGS_LBL))))

(define (default-set-narg cgc narg)
  (debug "default-set-narg: " narg "\n")
  (am-mov cgc (thread-descriptor narg-offset) (int-opnd narg)))

(define (default-check-poll cgc code)
  ;; Reminder: sp is the real stack pointer and fp is the simulated stack pointer
  ;; In memory
  ;; +++: underflow location
  ;; ++ : fp
  ;; +  : sp
  ;; 0  :
  ;; sp < fp < underflow
  (define (check-overflow)
    (debug "check-overflow\n")
    (am-cmp cgc fp sp)
    (am-jngu cgc OVERFLOW_LBL))
  (define (check-underflow)
    (debug "check-underflow\n")
    (load-mem-if-necessary cgc (thread-descriptor underflow-position-offset)
      (lambda (opnd)
        (am-cmp cgc opnd fp)
        (am-jnge cgc UNDERFLOW_LBL))))
  (define (check-interrupt)
    (debug "check-interrupt\n")
    (load-mem-if-necessary cgc (thread-descriptor interrupt-offset)
      (lambda (opnd)
        (am-cmp cgc opnd (int-opnd 0) word-width)
        (am-jnge cgc INTERRUPT_LBL))))

  (debug "default-check-poll\n")
  (let ((gvm-instr (code-gvm-instr code))
        (fs-gain (proc-frame-slots-gained code)))
    (if (jump-poll? gvm-instr)
      (begin
        (cond
          ((< 0 fs-gain) (check-overflow))
          ((> 0 fs-gain) (check-underflow)))
        (check-interrupt)))))

(define (default-make-opnd cgc proc code opnd context)
  (define (make-obj val)
    (cond
      ((fixnum? val)
        (int-opnd (tag-number val tag-mult fixnum-tag) word-width))
      ((null? val)
        (int-opnd (tag-number nil-object-val tag-mult special-int-tag) word-width))
      ((boolean? val)
        (int-opnd
          (if val
            (tag-number true-object-val  tag-mult special-int-tag)
            (tag-number false-object-val tag-mult special-int-tag)) word-width))
      ((proc-obj? val)
        (if (eqv? context 'jump)
          (get-proc-label cgc (obj-val opnd) 1)
          (lbl-opnd (get-proc-label cgc (obj-val opnd) 1))))
      ((string? val)
        (if (eqv? context 'jump)
          (make-object-label cgc (obj-val opnd))
          (lbl-opnd (make-object-label cgc (obj-val opnd)))))
      (else
        (compiler-internal-error "default-make-opnd: Unknown object type"))))
  (cond
    ((reg? opnd)
      (debug "reg\n")
      (get-register (reg-num opnd)))
    ((stk? opnd)
      (debug "stk\n")
      (if (eqv? context 'jump)
        (frame cgc (proc-jmp-frame-size code) (stk-num opnd))
        (frame cgc (proc-lbl-frame-size code) (stk-num opnd))))
    ((lbl? opnd)
      (debug "lbl\n")
      (if (eqv? context 'jump)
        (get-proc-label cgc proc (lbl-num opnd))
        (lbl-opnd (get-proc-label cgc proc (lbl-num opnd)))))
    ((obj? opnd)
      (debug "obj\n")
      (make-obj (obj-val opnd)))
    ((glo? opnd)
      (debug "glo: " (glo-name opnd) "\n")
      (compiler-internal-error "default-make-opnd: Opnd not implementeted global"))
    ((clo? opnd)
      (compiler-internal-error "default-make-opnd: Opnd not implementeted closure"))
    (else
      (compiler-internal-error "default-make-opnd: Unknown opnd: " opnd))))

;; ***** AM: Label table

;; Key: Label id
;; Value: Pair (Label, optional Proc-obj)
(define proc-labels (make-table test: eq?))

(define (get-proc-label cgc proc gvm-lbl)
  (define (nat-label-ref label-id)
    (let ((x (table-ref proc-labels label-id #f)))
      (if x
          (car x)
          (let ((l (asm-make-label cgc label-id)))
            (table-set! proc-labels label-id (list l proc))
            l))))

  (let* ((id (if gvm-lbl gvm-lbl 0))
         (label-id (lbl->id id (proc-obj-name proc))))
    (nat-label-ref label-id)))

;; Useful for branching
(define (make-unique-label cgc suffix?)
  (let* ((id (get-unique-id))
         (suffix (if suffix? suffix? "other"))
         (label-id (lbl->id id suffix))
         (l (asm-make-label cgc label-id)))
    (table-set! proc-labels label-id (list l #f))
    l))

(define (lbl->id num proc_name)
  (string->symbol (string-append "_proc_"
                                 (number->string num)
                                 "_"
                                 proc_name)))

; ***** AM: Object table and object creation

(define obj-labels (make-table test: equal?))

;; Store object reference or as int ???
(define (make-object-label cgc obj)
  (define (obj->id)
    (string->symbol (string-append "_obj_" (number->string (get-unique-id)))))

  (let* ((x (table-ref obj-labels obj #f)))
    (if x
        x
        (let* ((label (asm-make-label cgc (obj->id))))
          (table-set! obj-labels obj label)
          label))))

;; Provides unique ids
;; No need for randomness or UUID
;; *** Obviously, NOT thread safe ***
(define id 0)
(define (get-unique-id)
  (set! id (+ id 1))
  id)

;; ***** AM: Important labels

(define THREAD_DESCRIPTOR (asm-make-label cgc 'THREAD_DESCRIPTOR))
(define C_START_LBL (asm-make-label cgc 'C_START_LBL))
(define C_RETURN_LBL (asm-make-label cgc 'C_RETURN_LBL))
;; Exception handling procedures
(define WRONG_NARGS_LBL (asm-make-label cgc 'WRONG_NARGS_LBL))
(define OVERFLOW_LBL (asm-make-label cgc 'OVERFLOW_LBL))
(define UNDERFLOW_LBL (asm-make-label cgc 'UNDERFLOW_LBL))
(define INTERRUPT_LBL (asm-make-label cgc 'INTERRUPT_LBL))

;; ***** AM: Implementation constants

(define stack-size 10000) ;; Scheme stack size (bytes)
(define thread-descriptor-size 256) ;; Thread descriptor size (bytes) (Probably too much)
(define stack-underflow-padding 128) ;; Prevent underflow from writing thread descriptor (bytes)
(define offs 1) ;; stack offset so that frame[1] is at null offset from fp
(define runtime-result-register #f)

;; Thread descriptor offsets:
(define underflow-position-offset 8)
(define interrupt-offset 16)
(define narg-offset 24)

;; 64 = 01000000_2 = 0x40. -64 = 11000000_2 = 0xC0
;; 0xC0 unsigned = 192
(define na-reg-default-value -64)
(define na-reg-default-value-abs 192)

;; Pointer tagging constants
(define fixnum-tag 0)
(define object-tag 1)
(define special-int-tag 2)
(define pair-tag 3)

(define tag-mult 4)

;; Special int values
(define false-object-val 0) ;; Default value for false
(define true-object-val -1) ;; Default value for true
(define eof-object-val -100)
(define nil-object-val -1000)

(define na #f) ;; number of arguments register
(define sp #f) ;; Real stack limit
(define fp #f) ;; Simulated stack current pos
(define dp #f) ;; Thread descriptor register

;; Registers that map directly to GVM registers
(define main-registers #f)
;; Registers that can be overwritten at any moment!
;; Used when need extra register. Has to have at least 1 register.
(define work-registers #f)

;; ***** AM: Helper functions

(define (get-register n)
  (list-ref main-registers n))

(define (get-extra-register n)
  (list-ref work-registers n))

(define (alloc-frame cgc n)
  (if (not (= 0 n))
    (am-sub cgc fp (int-opnd (* n word-width-bytes)))))

(define (frame cgc fs n)
  (mem-opnd (* (+ fs (- n) offs) 8) fp))

(define (thread-descriptor offset)
  (mem-opnd (- offset na-reg-default-value-abs) dp))

(define (tag-number val mult tag)
  (+ (* mult val) tag))

(define (load-mem-if-necessary cgc mem-to-load f)
  (if load-store-only
    (begin
      (am-mov cgc (get-extra-register 0) mem-to-load)
      (f (get-extra-register 0)))
    (f mem-to-load)))

;;;----------------------------------------------------------------------------

;; ***** x64 code generation

(define (x86-64-backend targ
                        procs
                        output
                        c-intf
                        module-descr
                        unique-name
                        sem-changing-options
                        sem-preserving-options
                        cgc)

  (define (encode-proc proc)
    (map-proc-instrs
      (lambda (code)
        (encode-gvm-instr cgc proc code))
      proc))

  (debug "x86-64-backend\n")
  (asm-init-code-block cgc 0 'le)
  (x86-arch-set! cgc 'x86-64)
  (x64-setup)

  (add-start-routine cgc)
  (map-on-procs encode-proc procs)
  (add-end-routine cgc))

(define (x64-setup)
  (define (register-setup)
    (set! main-registers
      (list (x86-r15) (x86-r14) (x86-r13) (x86-r12) (x86-r11) (x86-r10)))
    (set! work-registers
      (list (x86-r9) (x86-r8)))
    (set! na (x86-cl))
    (set! sp (x86-rsp))
    (set! fp (x86-rdx))
    (set! dp (x86-rcx))
    (set! runtime-result-register (x86-rax)))

  (define (opnds-setup)
    (set! int-opnd x86-imm-int)
    (set! lbl-opnd x86-imm-lbl)
    (set! mem-opnd x86-mem))

  (define (instructions-setup)
    (set! am-lbl x86-label)
    (set! am-mov x86-mov)
    (set! am-lea x86-lea)
    (set! am-ret x86-ret)
    (set! am-cmp x86-cmp)
    (set! am-add x86-add)
    (set! am-sub x86-sub)

    (set! am-jmp    x86-jmp)
    ; (set! am-jmplink  doesnt-exist)
    (set! am-je     x86-je)
    (set! am-jne    x86-jne)
    (set! am-jg     x86-jg)
    (set! am-jng    x86-jle)
    (set! am-jge    x86-jge)
    (set! am-jnge   x86-jl)
    (set! am-jgu    x86-ja)
    (set! am-jngu   x86-jbe)
    (set! am-jgeu   x86-jae)
    (set! am-jngeu  x86-jb))

  (define (data-setup)
    (set! am-db x86-db)
    (set! am-dw x86-dw)
    (set! am-dd x86-dd)
    (set! am-dq x86-dq))

  (define (helper-setup)
    (set! am-set-narg   x64-set-narg)
    (set! am-check-narg x64-check-narg)
    ; (set! am-check-poll default-check-poll)
    ; (set! make-opnd default-make-opnd)
  )

  (define (make-parity-adjusted-valued n)
    (define (bit-count n)
      (if (= n 0)
        0
        (+ (modulo n 2) (bit-count (quotient n 2)))))
    (let* ((narg2 (* 2 (- n 3)))
          (bits (bit-count narg2))
          (parity (modulo bits 2)))
      (+ 64 parity narg2)))

  (define (x64-check-narg cgc narg)
    (debug "x64-check-narg: " narg "\n")
    (cond
      ((= narg 0)
        (am-jne cgc WRONG_NARGS_LBL))
      ((= narg 1)
        (x86-jp cgc WRONG_NARGS_LBL))
      ((= narg 2)
        (x86-jno cgc WRONG_NARGS_LBL))
      ((= narg 3)
        (x86-jns cgc WRONG_NARGS_LBL))
      ((<= narg 34)
          (am-sub cgc na (int-opnd (make-parity-adjusted-valued narg)))
          (am-jne cgc WRONG_NARGS_LBL))
      (else
        (default-check-narg cgc narg))))

  (define (x64-set-narg cgc narg)
    (debug "x64-set-narg: " narg "\n")
    (cond
      ((= narg 0)
        (am-cmp cgc na na))
      ((= narg 1)
        (am-cmp cgc na (int-opnd -65)))
      ((= narg 2)
        (am-cmp cgc na (int-opnd 66)))
      ((= narg 3)
        (am-cmp cgc na (int-opnd 0)))
      ((<= narg 34)
          (am-add cgc na (int-opnd (make-parity-adjusted-valued narg))))
      (else
        (default-set-narg cgc narg))))

  (register-setup)
  (opnds-setup)
  (instructions-setup)
  (data-setup)
  (helper-setup))

;; ***** Environment code and primitive functions

(define (add-start-routine cgc)
  (debug "add-start-routine\n")

  (am-lbl cgc C_START_LBL) ;; Initial procedure label
  ;; Thread descriptor initialization
  ;; Set thread descriptor address
  (am-mov cgc dp (lbl-opnd THREAD_DESCRIPTOR))
  ;; Set lower bytes of descriptor register used for passing narg
  (am-mov cgc na (int-opnd na-reg-default-value word-width))
  ;; Set underflow position to current stack pointer position
  (am-mov cgc (thread-descriptor underflow-position-offset) sp)
  ;; Set interrupt flag to current stack pointer position
  (am-mov cgc (thread-descriptor interrupt-offset) (int-opnd 0) word-width)
  (am-mov cgc (get-register 0) (lbl-opnd C_RETURN_LBL)) ;; Set return address for main
  (am-lea cgc fp (mem-opnd (* offs (- word-width-bytes)) sp)) ;; Align frame with offset
  (am-sub cgc sp (int-opnd stack-size)) ;; Allocate space for stack
  (am-set-narg cgc 0))

(define (add-end-routine cgc)
  (debug "add-end-routine\n")

  ;; Terminal procedure
  (am-lbl cgc C_RETURN_LBL)
  (am-add cgc sp (int-opnd stack-size))
  (am-mov cgc runtime-result-register (get-register 1))
  (am-ret cgc) ;; Exit program

  ;; Incorrect narg handling
  (am-lbl cgc WRONG_NARGS_LBL)
  ;; Overflow handling
  (am-lbl cgc OVERFLOW_LBL)
  ;; Underflow handling
  (am-lbl cgc UNDERFLOW_LBL)
  ;; Interrupts handling
  (am-lbl cgc INTERRUPT_LBL)
  ;; Pop stack
  (am-mov cgc fp (thread-descriptor underflow-position-offset))
  (am-mov cgc (get-register 0) (int-opnd -1)) ;; Error value
  ;; Pop remaining stack (Everything allocated but stack size
  (am-add cgc sp (int-opnd stack-size))
  (am-mov cgc runtime-result-register (int-opnd -4))
  (am-ret cgc 0)

  ;; Thread descriptor reserved space
  ;; Aligns address to 2^8 so the 8 least significant bits are 0
  ;; This is used to store the address in the lower bits of the cl register
  ;; The lower byte is used to pass narg
  ;; Also, align to descriptor to cache lines. TODO: Confirm it's true
  (asm-align cgc 256)
  (am-lbl cgc THREAD_DESCRIPTOR)
  (reserve-space cgc thread-descriptor-size 0) ;; Reserve space for thread-descriptor-size bytes

  ;; Add primitives
  (table-for-each
    (lambda (key val) (put-primitive-if-needed cgc key val))
    proc-labels)
  ;; Add objects
  (table-for-each
    (lambda (key val) (put-objects cgc key val))
    obj-labels)
)

;; Value is Pair (Label, optional Proc-obj)
(define (put-primitive-if-needed cgc key pair)
  (debug "put-primitive-if-needed\n")
  (let* ((label (car pair))
          (proc (cadr pair))
          (defined? (or (vector-ref label 1) (not proc)))) ;; See asm-label-pos (Same but without error if undefined)
    (if (not defined?)
      (let* ((prim (get-prim-obj (proc-obj-name proc)))
              (fun (prim-info-lifted-encode-fun prim)))
        (asm-align cgc 4 1)
        (am-lbl cgc label)
        (fun cgc label word-width)))))

;; Value is Pair (Label, optional Proc-obj)
(define (put-objects cgc obj label)
  (debug "put-objects\n")
  (debug "label: " label)

  ;; Todo : Alignment
  (am-lbl cgc label)

  (cond
    ((string? obj)
      (debug "Obj: " obj "\n")
      ;; Header: 158 (0x9E) + 256 * char_size(default:4) * length
      (am-dd cgc (+ 158 (* (* 256 4) (string-length obj))))
      ;; String content=
      (apply am-dd (cons cgc (map char->integer (string->list obj)))))
    (else
      (compiler-internal-error "put-objects: Unknown object type"))))

;; ***** x64 : GVM Instruction encoding

(define (encode-gvm-instr cgc proc code)
  ; (debug "encode-gvm-instr\n")
  (case (gvm-instr-type (code-gvm-instr code))
    ((label)  (encode-label-instr   cgc proc code))
    ((jump)   (encode-jump-instr    cgc proc code))
    ((ifjump) (encode-ifjump-instr  cgc proc code))
    ((apply)  (encode-apply-instr   cgc proc code))
    ((copy)   (encode-copy-instr    cgc proc code))
    ((close)  (encode-close-instr   cgc proc code))
    ((switch) (encode-switch-instr  cgc proc code))
    (else
      (compiler-error
        "encode-gvm-instr, unknown 'gvm-instr-type':" (gvm-instr-type gvm-instr)))))

;; ***** Label instruction encoding

(define (encode-label-instr cgc proc code)
  (debug "encode-label-instr: ")
  (let* ((gvm-instr (code-gvm-instr code))
         (label-num (label-lbl-num gvm-instr))
         (label (get-proc-label cgc proc label-num))
         (narg (label-entry-nb-parms gvm-instr)))

  (debug label "\n")

  ;; Todo: Check if alignment is necessary for task-entry/return
  (if (not (eqv? 'simple (label-type gvm-instr)))
    (asm-align cgc 4 1 144))

    (am-lbl cgc label)

    (if (eqv? 'entry (label-type gvm-instr))
      (am-check-narg cgc narg))))

;; ***** (if)Jump instruction encoding

(define (encode-jump-instr cgc proc code)
  (debug "encode-jump-instr\n")
  (let* ((gvm-instr (code-gvm-instr code))
         (jmp-opnd (jump-opnd gvm-instr)))

    ;; Pop stack if necessary
    (alloc-frame cgc (proc-frame-slots-gained code))

    (am-check-poll cgc code)

    ;; Save return address if necessary
    (if (jump-ret gvm-instr)
      (let* ((label-ret-num (jump-ret gvm-instr))
              (label-ret (get-proc-label cgc proc label-ret-num))
              (label-ret-opnd (lbl-opnd label-ret)))
        (am-mov cgc (get-register 0) label-ret-opnd)))

    ;; How to use am-jumplink (Branch with link like in ARM)
    ;; Problem: add-narg-set may change flag register
    ;; If isa support deactivating effects to register (Use global variable to toggle ex: (enable-flag-effects) (disable-flag-effects))
    ;;    Invert save-return-address and set-arg-count
    ;; Else, keep order

    ;; Set arg count
    (if (jump-nb-args gvm-instr)
      (am-set-narg cgc (jump-nb-args gvm-instr)))

    ;; Jump to location. Checks if jump is NOP.
    (let* ((label-num (label-lbl-num (bb-label-instr (code-bb code)))))
      (if (not (and (lbl? jmp-opnd) (= (lbl-num jmp-opnd) (+ 1 label-num))))
        (am-jmp cgc (make-opnd cgc proc code jmp-opnd 'jump))))))

(define (encode-ifjump-instr cgc proc code)
  (debug "encode-ifjump-instr\n")
  (let* ((gvm-instr (code-gvm-instr code))
          (true-label (get-proc-label cgc proc (ifjump-true gvm-instr)))
          (false-label (get-proc-label cgc proc (ifjump-false gvm-instr))))

    ;; Pop stack if necessary
    (alloc-frame cgc (proc-frame-slots-gained code))

    (am-check-poll cgc code)

    (x64-encode-prim-ifjump
      cgc
      proc
      code
      (get-prim-obj (proc-obj-name (ifjump-test gvm-instr)))
      (ifjump-opnds gvm-instr)
      true-label
      false-label)))

;; ***** Apply instruction encoding

(define (encode-apply-instr cgc proc code)
  (debug "encode-apply-instr\n")
  (let ((gvm-instr (code-gvm-instr code)))
    (x64-encode-prim-affectation
      cgc
      proc
      code
      (get-prim-obj (proc-obj-name (apply-prim gvm-instr)))
      (apply-opnds gvm-instr)
      (apply-loc gvm-instr))))

;; ***** Copy instruction encoding

(define (encode-copy-instr cgc proc code)
  (debug "encode-copy-instr\n")
  (let* ((gvm-instr (code-gvm-instr code))
        (src (make-opnd cgc proc code (copy-opnd gvm-instr) #f))
        (dst (make-opnd cgc proc code (copy-loc gvm-instr) #f)))
    (am-mov cgc dst src word-width)))

;; ***** Close instruction encoding

(define (encode-close-instr cgc proc gvm-instr)
  (debug "encode-close-instr\n")
  (compiler-internal-error
    "x64-encode-close-instr: close instruction not implemented"))

;; ***** Switch instruction encoding

(define (encode-switch-instr cgc proc gvm-instr)
  (debug "encode-switch-instr\n")
  (compiler-internal-error
    "x64-encode-switch-instr: switch instruction not implemented"))

;; ***** x64 primitives

;; symbol: prim symbol
;; extra-info: (return-type . more-info depending on type)
;; arity: Number of arguments accepted. #f is vararg (Is it possible?)
;; lifted-encode-fun: CGC -> Label -> Width (8|16|32|64) -> ().
;;    Generates function assembly code when called

;; inline-encode-fun: CGC -> Opnds* (Not in list) -> Width -> ().
;;    Generates inline assembly when called
;; args-need-reg: [Boolean]. #t if arg at the same index needs to be a register
;;    Otherwise, everything can be used (Do something for functions accepting memory loc by not constants)
(define (make-prim-info symbol extra-info arity lifted-encode-fun)
  (vector symbol extra-info arity lifted-encode-fun))

(define (make-inlinable-prim-info symbol extra-info arity lifted-encode-fun inline-encode-fun args-need-reg)
  (if (not (= (length args-need-reg) arity))
    (compiler-internal-error "make-inlinable-prim-info" symbol " arity /= (length args-need-reg)"))
  (vector symbol extra-info arity lifted-encode-fun inline-encode-fun args-need-reg))

(define (prim-info-inline? vect) (= 6 (vector-length vect)))

(define (prim-info-symbol vect) (vector-ref vect 0))
(define (prim-info-extra-info vect) (vector-ref vect 1))
(define (prim-info-arity vect) (vector-ref vect 2))
(define (prim-info-lifted-encode-fun vect) (vector-ref vect 3))
(define (prim-info-inline-encode-fun vect) (vector-ref vect 4))
(define (prim-info-args-need-reg vect) (vector-ref vect 5))

(define (prim-info-return-type vect) (car (prim-info-extra-info vect)))
(define (prim-info-true-jump vect) (cadr (prim-info-extra-info vect)))
(define (prim-info-false-jump vect) (caddr (prim-info-extra-info vect)))

(define (get-prim-obj prim-name)
  (case (string->symbol prim-name)
      ('##fx+ (prim-info-fx+))
      ('##fx- (prim-info-fx-))
      ('##fx< (prim-info-fx<))
      ('display (prim-info-display))
      (else
        (compiler-internal-error "Primitive not implemented: " prim-name))))

(define (prim-info-fx+)
  (define (lifted-encode-fun cgc label width)
    (x64-encode-lifted-prim-inline cgc (prim-info-fx+)))
  (make-inlinable-prim-info '##fx+ (list 'fixnum) 2 lifted-encode-fun x86-add '(#f #f)))

(define (prim-info-fx-)
  (define (lifted-encode-fun cgc label width)
    (x64-encode-lifted-prim-inline cgc (prim-info-fx-)))
  (make-inlinable-prim-info '##fx- (list 'fixnum) 2 lifted-encode-fun x86-sub '(#f #f)))

(define (prim-info-fx<)
  (define (lifted-encode-fun cgc label width)
    (x64-encode-lifted-prim-inline cgc (prim-info-fx<)))
  (make-inlinable-prim-info '##fx< (list 'boolean x86-jle x86-jg) 2 lifted-encode-fun x86-cmp '(#f #f)))

(define (prim-info-display)
  (define (lifted-encode-fun cgc label width)
    (x86-jmp cgc label)
    #f)
  (make-prim-info 'display (list 'fixnum) 1 lifted-encode-fun))

(define (prim-guard prim args)
  (define (reg-check opnd need-reg)
    (if (and need-reg (not (reg? opnd)))
      (compiler-internal-error "prim-guard " (prim-info-symbol prim) " one of it's argument isn't reg but is specified as one")))

  (if (not (= (length args) (prim-info-arity prim)))
    (compiler-internal-error (prim-info-symbol prim) "primitive doesn't have " (prim-info-arity prim) " operands"))

  (map reg-check args (prim-info-args-need-reg prim)))

(define (x64-encode-inline-prim cgc proc code prim args)
  (debug "x64-encode-inline-prim\n")
  (prim-guard prim args)
  (if (not (prim-info-inline? prim))
    (compiler-internal-error "x64-encode-inline-prim: " (prim-info-symbol prim) " isn't inlinable"))

  (let* ((opnds
          (map
            (lambda (opnd) (make-opnd cgc proc code opnd #f))
            args))
        (opnd1 (car opnds)))

  (apply (prim-info-inline-encode-fun prim) cgc (append opnds '(64)))))

;; Add mov necessary if operation only operates on register but args are not registers (todo? necessary?)
;; result-loc can be used to mov return after (False to disable)
(define (x64-encode-prim-affectation cgc proc code prim args result-loc)
  (debug "x64-encode-prim-affectation\n")
  (x64-encode-inline-prim cgc proc code prim args)

    (if (and result-loc (not (equal? (car args) result-loc)))
      (let ((result-loc-opnd (make-opnd cgc proc code result-loc #f)))
    (if (eqv? (prim-info-return-type prim) 'boolean) ;; We suppose arity > 0
      ;; If operation returns boolean (Result is in flag register)
        (let* ((proc-name (proc-obj-name proc))
                (suffix (string-append proc-name "_jump"))
                (label (make-unique-label cgc suffix)))

            (am-mov cgc result-loc-opnd (int-opnd 1))
            ((prim-info-true-jump prim) cgc label)
            (am-mov cgc result-loc-opnd (int-opnd 0))
            (am-label label))
      ;; Else
      (am-mov cgc result-loc-opnd (make-opnd cgc proc code (car args) #f))))))

;; Add mov necessary if operation only operates on register but args are not registers (todo? necessary?
(define (x64-encode-prim-ifjump cgc proc code prim args true-loc-label false-loc-label)
  (debug "x64-encode-prim-ifjump\n")
  (x64-encode-inline-prim cgc proc code prim args)

  ((prim-info-true-jump prim) cgc true-loc-label)
  (am-jmp cgc false-loc-label))

;; Defines lifted function using inline-encode-fun
(define (x64-encode-lifted-prim-inline cgc prim)
  (debug "x64-encode-lifted-prim\n")
  (let* ((opnds
          (cdr (take
            (vector->list main-registers)
            (prim-info-arity prim)))))

    (apply (prim-info-inline-encode-fun prim) cgc (append opnds '(64)))

    (if (eqv? (prim-info-return-type prim) 'boolean) ;; We suppose arity > 0
      ;; If operation returns boolean (Result is in flag register)
      (let* ((suffix "_jump")
              (label (make-unique-label cgc suffix))
              (result-loc (get-register 1)))

          (am-mov cgc (get-register 1) (int-opnd 1))
          ((prim-info-true-jump prim) cgc label)
          (am-mov cgc (get-register 1) (int-opnd 0))
          (am-label cgc label)))
      ;; Else, we suppose that arg1 is destination of operation. arg1 = r1

  (am-jmp cgc (get-register 0))))

;;;----------------------------------------------------------------------------

;; ***** GVM helper methods

(define (map-on-procs fn procs)
  (map fn (reachable-procs procs)))

(define (map-proc-instrs fn proc)
  (let ((p (proc-obj-code proc)))
        (if (bbs? p)
          (map fn (bbs->code-list p)))))

(define (proc-lbl-frame-size code)
  (bb-entry-frame-size (code-bb code)))

(define (proc-jmp-frame-size code)
  (bb-exit-frame-size (code-bb code)))

(define (proc-frame-slots-gained code)
  (bb-slots-gained (code-bb code)))

;;;============================================================================

;; ***** Utils

(define _debug #t)
(define (debug . str)
  (if _debug (for-each display str)))

(define (show-listing cgc)
  (asm-assemble-to-u8vector cgc)
  (asm-display-listing cgc (current-error-port) #t))

(define (reserve-space cgc bytes #!optional (value 0))
  (if (> bytes 0)
    (begin
      (am-db cgc value)
      (reserve-space cgc (- bytes 1) value))))