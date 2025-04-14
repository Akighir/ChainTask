;; Project Management System
;; A blockchain-based project tracking system with sequential tasks and milestone rewards

;; Constants
(define-constant ERR-NOT-PROJECT-MANAGER (err u1))
(define-constant ERR-PROJECT-NOT-ACTIVE (err u2))
(define-constant ERR-INVALID-TASK (err u3))
(define-constant ERR-ALREADY-COMPLETED (err u4))
(define-constant ERR-WRONG-DELIVERABLE (err u5))
(define-constant ERR-DEADLINE-NOT-REACHED (err u6))
(define-constant ERR-INSUFFICIENT-BUDGET (err u7))
(define-constant ERR-INVALID-PARAMETER (err u8))
(define-constant ERR-TASK-EXISTS (err u9))
(define-constant MAX-TASK-ID u100) ;; Maximum allowed task ID

;; Data Variables
(define-data-var project-manager principal tx-sender)
(define-data-var project-active bool false)
(define-data-var current-milestone uint u0)
(define-data-var onboarding-fee uint u1000000) ;; 1 STX
(define-data-var total-budget uint u0)
(define-data-var current-date uint u0) ;; Date tracking for deadlines

;; Task Structure
(define-map project-tasks
    uint
    {
        description: (string-utf8 256),
        deliverable-hash: (buff 32), ;; SHA256 hash of the expected deliverable
        deadline: uint,              ;; Deadline date for the task
        reward: uint,
        completed: bool
    }
)

;; Team Member Progress Tracking
(define-map team-member-progress
    principal
    {
        current-task: uint,
        completed-tasks: (list 20 uint),
        last-submission: uint,
        total-completed: uint
    }
)

;; Team Member Submission History
(define-map task-submissions
    {task: uint, member: principal}
    {
        attempts: uint,
        completed-at: (optional uint)
    }
)

;; Events
(define-map task-completions
    uint
    (list 10 {member: principal, completed-at: uint})
)

;; Authorization
(define-private (is-manager)
    (is-eq tx-sender (var-get project-manager)))

;; Date Management
(define-public (update-date (new-date uint))
    (begin
        (asserts! (is-manager) ERR-NOT-PROJECT-MANAGER)
        ;; Validate date is not in the past
        (asserts! (>= new-date (var-get current-date)) ERR-INVALID-PARAMETER)
        (var-set current-date new-date)
        (ok true)))

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
    (deadline uint)
    (reward uint))
    (begin
        (asserts! (is-manager) ERR-NOT-PROJECT-MANAGER)
        
        ;; Validate task-id is within acceptable range
        (asserts! (<= task-id MAX-TASK-ID) ERR-INVALID-PARAMETER)
        
        ;; Check if task already exists to prevent overwriting
        (asserts! (is-none (map-get? project-tasks task-id)) ERR-TASK-EXISTS)
        
        ;; Validate deadline is in the future
        (asserts! (>= deadline (var-get current-date)) ERR-INVALID-PARAMETER)
        
        ;; Validate deliverable hash is not empty
        (asserts! (> (len deliverable-hash) u0) ERR-INVALID-PARAMETER)
        
        ;; Validate description is not empty
        (asserts! (> (len description) u0) ERR-INVALID-PARAMETER)
        
        ;; Validate reward is a positive amount
        (asserts! (> reward u0) ERR-INVALID-PARAMETER)
        
        ;; Set the task data
        (map-set project-tasks task-id
            {
                description: description,
                deliverable-hash: deliverable-hash,
                deadline: deadline,
                reward: reward,
                completed: false
            })
            
        ;; Calculate new budget safely
        (let ((new-budget (+ (var-get total-budget) reward)))
            ;; Make sure the addition doesn't overflow
            (asserts! (>= new-budget (var-get total-budget)) ERR-INVALID-PARAMETER)
            ;; Update the total budget
            (var-set total-budget new-budget))
        (ok true)))

;; Team Member Onboarding
(define-public (join-team)
    (begin
        (asserts! (var-get project-active) ERR-PROJECT-NOT-ACTIVE)
        ;; Require onboarding fee
        (try! (stx-transfer? (var-get onboarding-fee) tx-sender (var-get project-manager)))
        
        (map-set team-member-progress tx-sender
            {
                current-task: u0,
                completed-tasks: (list),
                last-submission: u0,
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
        (today (var-get current-date))
        )
        ;; Check task availability
        (asserts! (var-get project-active) ERR-PROJECT-NOT-ACTIVE)
        (asserts! (>= today (get deadline task)) ERR-DEADLINE-NOT-REACHED)
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
                            (append (get completed-tasks member) task-id) u20)
                            ERR-INVALID-TASK),
                        total-completed: (+ (get total-completed member) u1)
                    }))
                
                ;; Record submission
                (map-set task-submissions
                    {task: task-id, member: tx-sender}
                    {
                        attempts: u1,
                        completed-at: (some today)
                    })
                
                ;; Award reward
                (try! (stx-transfer? (get reward task) (var-get project-manager) tx-sender))
                
                ;; Record completion
                (match (map-get? task-completions task-id)
                    completions (map-set task-completions task-id
                        (unwrap! (as-max-len?
                            (append completions {member: tx-sender, completed-at: today})
                            u10)
                            ERR-INVALID-TASK))
                    (map-set task-completions task-id
                        (list {member: tx-sender, completed-at: today})))
                
                (ok true))
            ERR-WRONG-DELIVERABLE)))

;; Read-only functions
(define-read-only (get-task-description (task-id uint))
    (match (map-get? project-tasks task-id)
        task (if (>= (var-get current-date) (get deadline task))
            (ok (get description task))
            ERR-DEADLINE-NOT-REACHED)
        ERR-INVALID-TASK))

(define-read-only (get-member-status (member principal))
    (map-get? team-member-progress member))

(define-read-only (get-task-completions (task-id uint))
    (map-get? task-completions task-id))

(define-read-only (get-current-date)
    (var-get current-date))

(define-read-only (get-project-stats)
    {
        active: (var-get project-active),
        current-milestone: (var-get current-milestone),
        total-budget: (var-get total-budget),
        onboarding-fee: (var-get onboarding-fee),
        current-date: (var-get current-date)
    })