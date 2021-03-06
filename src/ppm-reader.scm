;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; filename: ppm-reader.scm
;;
;; description: ascii PPM image format parser. The parse-ppm-image-file
;; function will parse the provided image file and return a ppm-image
;; data where the pixels are a list of pixel '(r g b) such that the
;; first pixel is the pixel corresponding to the lower right corner of
;; the image, just as the PPM format gives it.
;;
;; author: David St-Hilaire
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-type ppm-image width height color-depth pixels)

;; Strips comments from a ppm image file from stdin and outputs the
;; result on stdout
(define (strip-comments)
  (let loop ((line (read-line)))
    (if (not (eof-object? line))
        (begin
          (if (or (string=? line "")
                  (not (char=? (string-ref line 0) #\#)))
              (begin (display (string-append line "\n"))
                     (force-output)))
          (loop (read-line)))))
  (if (not (tty? (current-output-port)))
      (close-output-port (current-output-port))))

;; Parses a ppm image from the stdin into a scheme ppm-image type.
(define (parse-ppm-image)
  (if (not (eq? (read) 'P3))
      (error "unsupported ppm format"))
  (let ((width (read))
        (height (read))
        (color-depth (read)))
    (let loop ((index 0) (data (read)) (current-pixel '()) (pixels '()))
      (if (eof-object? data)
          (if (not (= index 0))
              (error "bad image format detected...")
              (make-ppm-image width height color-depth pixels))
          (if (= index 2)
              (loop 0 (read) '() (cons (reverse (cons data current-pixel))
                                       pixels))
              (loop (+ index 1) (read) (cons data current-pixel) pixels))))))

(define (parse-ppm-image-file filename)
  (if (not (file-exists? filename))
      (error (string-append "Image " filename " does not exists.")))
  (pipe
   (lambda () (with-input-from-file filename strip-comments))
   parse-ppm-image))

;; Function that will return a list of 2d coordinate of type pos2d
;; where each of the returned points are pixels in the image where a
;; certain condition on the rgb color must be respected. The result of
;; (test-rgb? r g b) is the condition used to determine which points
;; are filtered and which are not.
(define (rgb-pixels-to-boolean-point-list ppm-data test-rgb? . options)
  (define width (ppm-image-width ppm-data))
  (define x-adjust (if (memq 'center options)
                       (lambda (x) (- x (floor (/ width 2))))
                       (lambda (x) x)))
  
  (let loop ((y 0) (x 0) (pixels (ppm-image-pixels ppm-data)) (acc '()))
    (if (not (pair? pixels))
        (reverse (cleanse acc))
        (let* ((current-pixel (car pixels))
               (r (car current-pixel))
               (g (cadr current-pixel))
               (b (caddr current-pixel))
               (new-c (modulo (+ x 1) width)))
          (loop (if (= new-c 0) (+ y 1) y) new-c (cdr pixels)
                (cons (if (test-rgb? r g b)
                          (make-pos2d (x-adjust x) y)
                          '())
                      acc))))))