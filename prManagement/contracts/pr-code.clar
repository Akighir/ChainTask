;; SECURE-COMMUNICATION-PROTOCOL - SIMPLIFIED VERSION
;; Basic implementation with entity registration and message passing

;; Error codes
(define-constant ERR-NOT-AUTHORIZED u401)
(define-constant ERR-ENTITY-EXISTS u402)
(define-constant ERR-ENTITY-NOT-FOUND u403)
(define-constant ERR-MESSAGE-NOT-FOUND u404)
(define-constant ERR-MESSAGE-TOO-LARGE u405)

;; System parameters
(define-constant MAX-MESSAGE-SIZE u1024)
(define-constant MAX-MAILBOX-SIZE u25)

;; System state
(define-data-var message-counter uint u0)
(define-data-var entity-counter uint u0)
(define-data-var temp-target-id uint u0)

;; Data structures
(define-map entities principal 
  {
    active: bool,
    crypto-key: (buff 33),
    registration-time: uint,
    message-count: uint
  }
)

(define-map messages uint 
  {
    sender: principal,
    recipient: principal,
    content: (buff 1024),
    timestamp: uint,
    read: bool
  }
)

(define-map user-mailbox principal (list 25 uint))

;; Helper function to get current time
(define-private (get-current-time)
  (default-to u0 (get-block-info? time u0))
)

;; Read-only functions
(define-read-only (get-entity-info (user principal))
  (map-get? entities user)
)

(define-read-only (is-entity-registered (user principal))
  (is-some (map-get? entities user))
)

(define-read-only (get-message (message-id uint))
  (map-get? messages message-id)
)

(define-read-only (get-mailbox (user principal))
  (default-to (list) (map-get? user-mailbox user))
)

(define-read-only (get-system-stats)
  {
    total-messages: (var-get message-counter),
    total-entities: (var-get entity-counter)
  }
)

;; Entity registration
(define-public (register-entity (crypto-key (buff 33)))
  (let (
    (caller tx-sender)
    (current-time (get-current-time))
  )
    ;; Check if entity already exists
    (asserts! (not (is-entity-registered caller)) 
              (err ERR-ENTITY-EXISTS))
    
    ;; Register the entity
    (map-set entities caller
      {
        active: true,
        crypto-key: crypto-key,
        registration-time: current-time,
        message-count: u0
      }
    )
    
    ;; Initialize empty mailbox
    (map-set user-mailbox caller (list))
    
    ;; Update counter
    (var-set entity-counter (+ (var-get entity-counter) u1))
    (ok true)
  )
)

;; Send message
(define-public (send-message (recipient principal) (content (buff 1024)))
  (let (
    (caller tx-sender)
    (message-id (var-get message-counter))
    (current-time (get-current-time))
    (sender-info (unwrap! (get-entity-info caller) (err ERR-ENTITY-NOT-FOUND)))
    (recipient-mailbox (get-mailbox recipient))
  )
    ;; Verify sender is registered
    (asserts! (is-entity-registered caller) 
              (err ERR-ENTITY-NOT-FOUND))
    
    ;; Verify recipient is registered
    (asserts! (is-entity-registered recipient) 
              (err ERR-ENTITY-NOT-FOUND))
    
    ;; Check mailbox size limit
    (asserts! (< (len recipient-mailbox) MAX-MAILBOX-SIZE)
              (err ERR-MESSAGE-TOO-LARGE))
    
    ;; Store the message
    (map-set messages message-id
      {
        sender: caller,
        recipient: recipient,
        content: content,
        timestamp: current-time,
        read: false
      }
    )
    
    ;; Add to recipient's mailbox (safe append since we checked size)
    (map-set user-mailbox 
             recipient
             (unwrap-panic (as-max-len? (append recipient-mailbox message-id) u25)))
    
    ;; Update sender's message count
    (map-set entities caller
      (merge sender-info { 
        message-count: (+ (get message-count sender-info) u1)
      })
    )
    
    ;; Increment message counter
    (var-set message-counter (+ message-id u1))
    
    (ok message-id)
  )
)

;; Mark message as read
(define-public (read-message (message-id uint))
  (let (
    (caller tx-sender)
    (message-data (unwrap! (get-message message-id) (err ERR-MESSAGE-NOT-FOUND)))
  )
    ;; Verify caller is the recipient
    (asserts! (is-eq (get recipient message-data) caller) 
              (err ERR-NOT-AUTHORIZED))
    
    ;; Mark as read
    (map-set messages message-id
      (merge message-data { read: true })
    )
    
    (ok true)
  )
)

;; Delete message
(define-public (delete-message (message-id uint))
  (let (
    (caller tx-sender)
    (message-data (unwrap! (get-message message-id) (err ERR-MESSAGE-NOT-FOUND)))
  )
    ;; Verify caller is sender or recipient
    (asserts! (or 
               (is-eq (get sender message-data) caller)
               (is-eq (get recipient message-data) caller))
             (err ERR-NOT-AUTHORIZED))
    
    ;; Remove from mailbox if caller is recipient
    (if (is-eq (get recipient message-data) caller)
        (begin
          (var-set temp-target-id message-id)
          (map-set user-mailbox 
                   caller 
                   (fold remove-target-id (get-mailbox caller) (list))))
        true)
    
    ;; Delete the message
    (map-delete messages message-id)
    
    (ok true)
  )
)

;; Fold function to build new list without target ID
(define-private (remove-target-id (item uint) (acc (list 25 uint)))
  (if (is-eq item (var-get temp-target-id))
      acc
      (unwrap-panic (as-max-len? (append acc item) u25)))
)

;; Update crypto key
(define-public (update-crypto-key (new-key (buff 33)))
  (let (
    (caller tx-sender)
    (entity-info (unwrap! (get-entity-info caller) (err ERR-ENTITY-NOT-FOUND)))
  )
    ;; Update the crypto key
    (map-set entities caller
      (merge entity-info { crypto-key: new-key })
    )
    
    (ok true)
  )
)