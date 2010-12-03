;;
;; Copyright (c) 2010, Peter Seibel. All rights reserved.
;;

(in-package com.gigamonkeys.markup3)

;;(declaim (optimize (debug 3)))

(defparameter *spaces-per-tab* 8)

(defparameter *blank* (format nil "~c~c" #\Newline #\Newline))

(defparameter *blockquote-indentation* 2)

(defparameter *verbatim-indentation* 3)

(defclass parser ()
  ((bindings :initform () :accessor bindings)
   (elements :initform () :accessor elements)
   (current-indentation :initform 0 :accessor current-indentation)
   (subdocument-tags 
    :initarg :subdocument-tags
    :initform '(:note :comment)
    :accessor subdocument-tags)
   (parse-links-p :initarg :parse-links-p :initform t :accessor parse-links-p)))

(defclass element ()
  ((tag :initarg :tag :accessor tag)
   (current-child-cons :initform nil :accessor current-child-cons)
   (children :initform nil :accessor children)))

(defmethod print-object ((object element) stream)
  (print-unreadable-object (object stream)
    (format stream "tag: ~a" (tag object))))

(defclass token ()
  ((offset :initarg :offset :accessor offset)
   (content :initarg :content :accessor content)))

(defmethod print-object ((object token) stream)
  (print-unreadable-object (object stream :type t)
    (format stream "content: ~a offset: ~a" (content object) (offset object))))

(defclass indentation (token)
  ((spaces :initarg :spaces :accessor spaces)))

(defclass blank-lines (token)
  ((lines :initarg :lines :accessor lines)))

(defmethod print-object ((object indentation) stream)
  (print-unreadable-object (object stream :type t :identity nil)
    (format stream "~a" (spaces object))))

;;
;; Our main macro.
;; 

(defmacro with-bindings ((parser token) &body bindings)
  (with-gensyms (frame-marker)
    `(let ((,frame-marker (open-frame ,parser)))
       (flet ((pop-frame ()
                (close-frame ,parser ,frame-marker))
              (pop-frame-and-element (element)
                (close-frame ,parser ,frame-marker)
                (close-element ,parser element)))
         (declare (ignorable (function pop-frame) (function pop-frame-and-element)))
         ,@(loop for (key . body) in (reverse bindings) collect
                `(push-binding 
                  ,parser 
                  ,(etypecase key
                              (character key)
                              (symbol key)
                              (string key)
                              (cons `(lambda (,token) (declare (ignorable ,token)) ,key)))
                  (lambda (,token) (declare (ignorable ,token)) ,@body)))))))

(defun token-is (token what)
  (eql (content token) what))

(defun blank-p (token)
  (typep token 'blank-lines))

(defun %indentation-compare (token spaces cmp)
  (and (typep token 'indentation) (funcall cmp (spaces token) spaces)))

(defun indentation= (token spaces)
  (%indentation-compare token spaces #'=))

(defun indentation< (token spaces)
  (%indentation-compare token spaces #'<))

(defun indentation>= (token spaces)
  (%indentation-compare token spaces #'>=))

(defgeneric to-sexp (thing))

(defmethod to-sexp ((string string)) string)

(defmethod to-sexp ((element element))
  `(,(tag element) ,@(loop with last = (current-child-cons element)
                        for cons on (children element)
                        for child = (car cons)
                        collect (to-sexp 
                                 (if (and (eql cons last) (stringp child))
                                     (string-right-trim " " child)
                                     child)))))

(defun append-child (element child)
  (let ((cons (current-child-cons element))
        (new-cons (cons child nil)))
    (when cons (setf (cdr cons) new-cons))
    (unless (children element)
      (setf (children element) new-cons))
    (setf (current-child-cons element) new-cons)))

(defun current-child (element)
  (car (current-child-cons element)))

(defmethod initialize-instance :after ((parser parser) &key &allow-other-keys)
  (push-binding parser t (lambda (tok) (error "No binding for ~s in ~s" tok (bindings parser)))))

(defun open-frame (parser)
  (let ((marker (gensym "FRAME-")))
    (push-binding parser marker nil)
    marker))

(defun close-frame (parser frame-marker)
  (with-slots (bindings) parser
    (setf bindings (cdr (member frame-marker bindings :key #'car)))))

(defun push-binding (parser key fn)
  (with-slots (bindings) parser
    (setf bindings (acons key fn bindings))))

(defun find-binding (parser token)
  "Find the first binding that could handle the given token. A default
  binding can be established with the key t"
  (with-slots (bindings) parser
    (cdr (assoc token bindings :test #'key-match))))

(defun key-match (token key)
  (etypecase key
    ((eql t) t)
    (character (token-is token key))
    (function (funcall key token))
    (string (find (content token) key))
    (symbol (token-is token key))))

(defun open-element (parser tag)
  (with-slots (elements) parser
    (let ((parent (first elements))
          (element (make-instance 'element :tag (intern (string-upcase tag) :keyword))))
      (when parent (append-child parent element))
      (push element elements)
      element)))

(defun close-element (parser element)
  (with-slots (elements) parser
    (let ((tail (member element elements)))
      (unless tail (error "~a is not in elements (~a)." element elements))
      (setf elements (cdr tail)))
    element))

(defun parse-file (file &key (parse-links-p t) (subdocument-tags '(:note :comment)))
  (let* ((parser (make-instance 'parser :parse-links-p parse-links-p :subdocument-tags subdocument-tags))
         (translator (make-basic-translator-chain (lambda (tok) (process-token parser tok))))
         (body (open-document parser)))
    (funcall translator #\Newline)
    (funcall translator #\Newline)
    (with-open-file (in file)
      (loop for c = (read-char in nil nil) while c do (funcall translator c)))
    (funcall translator #\Newline)
    (funcall translator #\Newline)
    (funcall translator :eof)
    (to-sexp body)))

(defun process-token (parser token)
  (funcall (find-binding parser token) token))

(defun open-document (parser)
  (let ((body (open-element parser "body")))
    (with-bindings (parser token)
      (#\* (open-header-handler parser))

      (#\- (open-possible-modeline-handler parser))

      (#\[ 
       (open-possible-link-definition parser)
       (process-token parser token))

      ((or (text-char-p token) (token-is token #\\))
       (open-paragraph parser "p")
       (process-token parser token))

      ((indentation>= token (+ (current-indentation parser) *verbatim-indentation*))
       (incf (current-indentation parser) *verbatim-indentation*)
       (open-verbatim parser (- (spaces token) (current-indentation parser))))
  
      ((indentation=  token (+ (current-indentation parser) *blockquote-indentation*))
       (incf (current-indentation parser) *blockquote-indentation*)
       (open-blockquote-or-list parser (spaces token)))
  
      ((indentation= token (current-indentation parser)))
    
      ((blank-p token))
    
      (:eof (pop-frame-and-element body)))
    body))

(defun open-paragraph (parser tag)
  (paragraph-bindings parser (open-element parser tag)))


(defun paragraph-bindings (parser paragraph)
  (with-bindings (parser token)
    (#\\ (open-slash-handler parser))
    ((and (parse-links-p parser) (token-is token #\[)) (open-link parser))
    (#\Newline (add-text parser #\Space))
    ((text-char-p token) (add-text parser token))
    ((blank-p token) (pop-frame-and-element paragraph))))

(defun open-block (parser tag)
  (let ((element (open-element parser tag)))
    (with-bindings (parser token)
      (#\} (pop-frame-and-element element)))))

(defun open-subdocument (parser tag)
  (let ((element (open-element parser tag))
        (original-indentation (current-indentation parser)))
    (with-bindings (parser token)
      (:eof (error "Subdocument ~a not closed." tag))

      (#\} 
       (setf (current-indentation parser) original-indentation)
       (pop-frame-and-element element))

      ;; We need these two binding that seemingly duplicate the ones
      ;; in open-document because the open-paragraph binding for
      ;; text-chars will shadow the open-document ones.
      (#\* (open-header-handler parser))
      
      ((or (text-char-p token) (token-is token #\\))
       (open-paragraph parser "p")
       (process-token parser token)))))

(defun open-blockquote-or-list (parser indentation)
  (let ((section (open-element parser "blockquote")))
    (with-bindings (parser token)

      ("#-"
       (setf (tag section) (case (content token) (#\# :ol) (#\- :ul)))
       (open-list parser token indentation)
       (process-token parser token))

      ((indentation= token (+ (- indentation *blockquote-indentation*) *verbatim-indentation*))
       ;; This is a bit of a kludge. We need to fall through to the
       ;; underlying document indentation handlers but they won't work
       ;; until we change the parser's current-indentation. Which
       ;; suggests that's maybe a wrong approach.
       (decf (current-indentation parser) *blockquote-indentation*)
       (pop-frame-and-element section)
       (process-token parser token))

      ((indentation< token indentation)
       (setf (current-indentation parser) (spaces token))
       (pop-frame-and-element section)
       (process-token parser token)))))

(defun open-list (parser list-marker indentation)
  (with-bindings (parser token)

    ((indentation< token indentation)
     (setf (current-indentation parser) (spaces token))
     (pop-frame)
     (process-token parser token))

    ((eql token list-marker)
     (with-bindings (parser token)
       (#\Space 
        (pop-frame)
        (setf (current-indentation parser) (+ indentation 2))
        (open-list-item parser list-marker (+ indentation 2)))
       (t (illegal-token token))))))

(defun open-list-item (parser list-marker indentation)
  (let ((item (open-element parser "li")))
    (with-bindings (parser token)
      ((indentation< token indentation)
       (setf (current-indentation parser) (spaces token))
       (pop-frame-and-element item)
       (process-token parser token))

      ((eql list-marker (content token))
       (pop-frame-and-element item)
       (process-token parser token)))))

(defun open-verbatim (parser extra-indentation)
  (let ((verbatim (open-element parser "pre"))
        (blanks 0)
        (bol t))

    (with-bindings (parser token)
      (#\Newline 
       (add-text parser token)
       (setf bol t))

      ((blank-p token)
       (incf blanks (lines token))
       (setf bol t))

      ((characterp (content token))
       (when bol
         (loop repeat blanks do (add-text parser #\Newline))
         (setf blanks 0)
         (loop repeat extra-indentation do (add-text parser #\Space))
         (setf bol nil))
       (add-text parser token))

      ((indentation>= token (current-indentation parser))
       (setf extra-indentation (- (spaces token) (current-indentation parser))))

      ((indentation< token (current-indentation parser))
       (decf (current-indentation parser) *verbatim-indentation*)
       (pop-frame-and-element verbatim)
       (process-token parser token)))))

(defun open-header-handler (parser)
  (let ((level 1))
    (with-bindings (parser token)
      (#\* (incf level))
      (#\Space 
       (pop-frame)
       (open-paragraph parser (format nil "h~d" level)))
      (t (illegal-token token)))))

(defun open-possible-modeline-handler (parser)
  (let ((so-far (make-text-buffer "-"))
        (inital-offset 0))
    (with-bindings (parser token)
      ((and (token-is token #\*) (string= so-far "-"))
       (setf inital-offset (- (offset token) 2))
       (append-text so-far token))
      ((and (token-is token #\-) (string= so-far "-*"))
       (append-text so-far token))
      ((string= so-far "-*-")
       (when (blank-p token) (pop-frame)))
      (t
       (append-text so-far token)
       (pop-frame)
       (open-paragraph parser "p")
       (loop for c across so-far
          for o from inital-offset
          do (process-token parser (token c o)))))))

(defun open-possible-link-definition (parser)
  ;; This is either a paragraph starting with a link or a link
  ;; definition.
  (let ((possible-link-def (open-element parser "p"))
        (spaces 0))
    (with-bindings (parser token)
      (#\[ (open-link parser))
      (#\Space (incf spaces))
      (#\<  
       (setf (tag possible-link-def) :link_def)
       (open-url parser))
      ((or (text-char-p token) (token-is token #\\))
       (pop-frame)
       (paragraph-bindings parser possible-link-def)
       (when (plusp spaces)
         (process-token parser (make-instance 'token :content #\Space :offset (1- (offset token)))))
       (process-token parser token))
      ((blank-p token) (pop-frame-and-element possible-link-def)))))

(defun open-link (parser)
  (let ((link (open-element parser "link")))
    (with-bindings (parser token)
      (#\] (pop-frame-and-element link))
      (#\Newline (add-text parser #\Space))
      (#\| (open-link-key parser))
      ((text-char-p token) (add-text parser token)))
    link))

(defun open-link-key (parser)
  (let ((key (open-element parser "key")))
    (with-bindings (parser token)
      (#\]
       (pop-frame-and-element key)
       (process-token parser token))
      (#\Newline (add-text parser #\Space))
      ((text-char-p token) (add-text parser token)))))

(defun open-url (parser)
  (let ((url (open-element parser "url")))
    (with-bindings (parser token)
      (#\> (pop-frame-and-element url))
      ((url-char-p token) (add-text parser token))
      (t (error "Illegal token in link definition ~s" token)))))
       
(defun open-slash-handler (parser)
  (with-bindings (parser token)
    ((not (tag-name-char-p token))
     (pop-frame)
     (add-text parser token))
    ((tag-name-char-p token)
     (pop-frame)
     (open-tag-name-handler parser token))))

(defun open-tag-name-handler (parser token)
  (let ((name (make-text-buffer token)))
    (with-bindings (parser token)
      (#\{
       (unless (plusp (length name))
         (error "Empty names not allowed."))
       (pop-frame)
       (if (find name (subdocument-tags parser) :test #'string-equal)
           (open-subdocument parser name)
           (open-block parser name)))
      ((tag-name-char-p token)
       (append-text name token)))))

(defun text-char-p (token)
  "Characters that can appear unescaped in non-verbatim sections."
  (let ((char (content token)))
    (and (characterp char) (not (find char "\\{}")))))

(defun url-char-p (token)
  ;; FIXME -- this could be made better.
  (let ((char (content token)))
    (and (characterp char) (not (eql char #\>)))))

(defun tag-name-char-p (token)
  "Characters that can appear in tag names (i.e. between a '\' and a '{')."
  (let ((char (content token)))
    (and (characterp char) 
         (or (alphanumericp char)
             (find char "_.+")))))

(defun add-text (parser text)
  (let ((element (first (elements parser))))
    (if (stringp (current-child element))
        (append-text (current-child element) text)
        (append-child element (make-text-buffer text)))))

(defun make-text-buffer (&optional text)
  (let ((s (make-array 10 :element-type 'character :adjustable t :fill-pointer 0)))
    (when text (append-text s text))
    s))

(defun append-text (string text)
  (typecase text
    (token (append-text string (content text)))
    (character (vector-push-extend text string))
    (string (loop for c across text do (vector-push-extend c string)))
    (t (format t "~&Appending non text text: ~a" text))))


(defun illegal-token (token) (error "Illegal token ~a" token))

;;
;; Character translators -- cleans up input and generates blanks and indentations
;;

(defun token (content offset)
  (make-instance 'token :content content :offset offset))

(defun make-tokenizer (next)
  (let ((offset -1))
    (lambda (char)
      (funcall next (token char (incf offset))))))

(defun make-tab-translator (next)
  "Translate Tab characters to *spaces-per-tab* Space characters."
  (lambda (token)
    (case (content token)
      (#\Tab (loop repeat *spaces-per-tab* do (funcall next (token #\Space (offset token)))))
      (t (funcall next token)))))

(defun make-eol-translator (next)
  "Translate CRLF and CR to LF"
  (let ((after-cr nil))
    (lambda (token)
      (case (content token)
        (#\Return (setf after-cr t))
        (t (cond
             (after-cr 
              (funcall next (token #\Newline (1- (offset token))))
              (unless (token-is token #\Newline) (funcall next token)))
             (t (funcall next token)))
           (setf after-cr nil))))))

(defun make-trailing-space-translator (next)
  (let ((spaces-seen 0))
    (lambda (token)
      (case (content token)
        (#\Space (incf spaces-seen))
        (t (unless (token-is token #\Newline)
             (loop repeat spaces-seen
                for offset from (- (offset token) spaces-seen)
                do (funcall next (token #\Space offset))))
           (setf spaces-seen 0)
           (funcall next token))))))

(defun make-blank-translator (next)
  "Translate more than one consecutive newlines into a blank-line token"
  (let ((newlines-seen 0))
    (lambda (token)
      (case (content token)
        (#\Newline (incf newlines-seen))
        (t (cond
             ((= newlines-seen 1) (funcall next (token #\Newline (1- (offset token)))))
             ((> newlines-seen 1) (funcall next (make-instance 'blank-lines
                                                  :lines newlines-seen
                                                  :content :blank
                                                  :offset (1- (offset token))))))
           (setf newlines-seen 0)
           (funcall next token))))))

(defun make-indentation-translator (next)
  "Translate leading spaces into INDENTATION tokens."
  (let ((in-indentation t)
        (spaces-seen 0))
    (lambda (token)
      (cond
        ((and in-indentation (token-is token #\Space))
         (incf spaces-seen))
        ((or (token-is token #\Newline) (blank-p token))
         (setf spaces-seen 0)
         (setf in-indentation t)
         (funcall next token))
        (t
         (when in-indentation
           (funcall next (make-instance 'indentation :spaces spaces-seen :content :indent :offset (- (offset token) spaces-seen)))
           (setf in-indentation nil))
         (funcall next token))))))

(defun make-basic-translator-chain (end)
  (make-tokenizer
   (make-tab-translator 
    (make-eol-translator
     (make-trailing-space-translator
      (make-blank-translator
       (make-indentation-translator end)))))))