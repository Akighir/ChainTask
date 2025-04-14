;; Project Management System

;; Constants
(define-constant ERR-NOT-PROJECT-MANAGER (err u1))
(define-constant ERR-PROJECT-NOT-ACTIVE (err u2))
(define-constant ERR-INVALID-TASK (err u3))
(define-constant ERR-ALREADY-COMPLETED (err u4))
(define-constant ERR-WRONG-DELIVERABLE (err u5))
(define-constant MAX-TASK-ID u50) ;; Maximum allowed task ID

;; Data Variables
(define-data-var project-manager principal tx-sender)
(define-data-var project-active bool false)
(define-data-var current-milestone uint u0)
(define-data-var total-budget uint u0)

;; Task Structure
(define-map project-tasks
    uint
    {
        description: (string-utf8 256),
        deliverable-hash: (buff 32), ;; SHA256 hash of the expected deliverable
        reward: uint,
        completed: bool
    }
)

;; Team Member Progress Tracking
(define-map team-member-progress
    principal
    {
        current-task: uint,
        completed-tasks: (list 10 uint),
        total-completed: uint
    }
)

;; Authorization
(define-private (is-manager)
    (is-eq tx-sender (var-get project-manager)))

;; Project Management Functions
(define-public (initialize-project)
    (begin
        (asserts! (is-manager) ERR-NOT-PROJECT-MANAGER)
        (var-set project-active true)
        (var-set current-milestone u0)
        (var-set total-budget u0)
        (ok true)))

(define-public (add-task
    (task-id uint)
    (description (string-utf8 256))
    (deliverable-hash (buff 32))
    (reward uint))
    (begin
        (asserts! (is-manager) ERR-NOT-PROJECT-MANAGER)
        
        ;; Validate task-id is within acceptable range
        (asserts! (<= task-id MAX-TASK-ID) ERR-INVALID-TASK)
        
        ;; Set the task data
        (map-set project-tasks task-id
            {
                description: description,
                deliverable-hash: deliverable-hash,
                reward: reward,
                completed: false
            })
            
        ;; Update the total budget
        (var-set total-budget (+ (var-get total-budget) reward))
        (ok true)))

;; Team Member Onboarding
(define-public (join-team)
    (begin
        (asserts! (var-get project-active) ERR-PROJECT-NOT-ACTIVE)
        
        (map-set team-member-progress tx-sender
            {
                current-task: u0,
                completed-tasks: (list),
                total-completed: u0
            })
        (ok true)))

;; Task Completion Functions
(define-public (submit-deliverable
    (task-id uint)
    (deliverable (buff 32)))
    (let (
        (task (unwrap! (map-get? project-tasks task-id) ERR-INVALID-TASK))
        (member (unwrap! (map-get? team-member-progress tx-sender) ERR-INVALID-TASK))
        )
        ;; Check task availability
        (asserts! (var-get project-active) ERR-PROJECT-NOT-ACTIVE)
        (asserts! (not (get completed task)) ERR-ALREADY-COMPLETED)
        
        ;; Verify deliverable - directly compare the hashes
        (if (is-eq deliverable (get deliverable-hash task))
            (begin
                ;; Update task status
                (map-set project-tasks task-id
                    (merge task {completed: true}))
                
                ;; Update team member progress
                (map-set team-member-progress tx-sender
                    (merge member {
                        current-task: (+ task-id u1),
                        completed-tasks: (unwrap! (as-max-len? 
                            (append (get completed-tasks member) task-id) u10)
                            ERR-INVALID-TASK),
                        total-completed: (+ (get total-completed member) u1)
                    }))
                
                ;; Award reward
                (try! (stx-transfer? (get reward task) (var-get project-manager) tx-sender))
                
                (ok true))
            ERR-WRONG-DELIVERABLE)))

;; Read-only functions
(define-read-only (get-task-description (task-id uint))
    (match (map-get? project-tasks task-id)
        task (ok (get description task))
        ERR-INVALID-TASK))

(define-read-only (get-member-status (member principal))
    (map-get? team-member-progress member))

(define-read-only (get-project-stats)
    {
        active: (var-get project-active),
        current-milestone: (var-get current-milestone),
        total-budget: (var-get total-budget)
    })