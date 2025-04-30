;; pulse-stride.clar

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PulseStride Step Challenge
;;
;; This contract manages the PulseStride platform, a system for creating and 
;; participating in global step-counting challenges and virtual marathons.
;; 
;; The contract handles:
;; - Challenge creation with customizable parameters
;; - User registration and participation
;; - Step count validation and recording
;; - Reward distribution at challenge completion
;; - Anti-cheating mechanisms and access controls
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CHALLENGE-NOT-FOUND (err u101))
(define-constant ERR-USER-ALREADY-REGISTERED (err u102))
(define-constant ERR-CHALLENGE-CLOSED (err u103))
(define-constant ERR-INADEQUATE-PAYMENT (err u104))
(define-constant ERR-CHALLENGE-ACTIVE (err u105))
(define-constant ERR-CHALLENGE-NOT-COMPLETE (err u106))
(define-constant ERR-USER-NOT-REGISTERED (err u107))
(define-constant ERR-STEP-SUBMISSION-INVALID (err u108))
(define-constant ERR-DAILY-STEP-LIMIT-EXCEEDED (err u109))
(define-constant ERR-INVALID-PARAMETERS (err u110))
(define-constant ERR-ALREADY-SUBMITTED-TODAY (err u111))
(define-constant ERR-CHALLENGE-ALREADY-EXISTS (err u112))
(define-constant ERR-NOT-DATA-PROVIDER (err u113))

;; Constants
(define-constant MAX-DAILY-STEPS u50000) ;; Reasonable upper limit for step count
(define-constant CONTRACT-OWNER tx-sender) ;; Set contract deployer as owner
(define-constant REWARD-PRECISION u1000000) ;; For calculating percentages

;; Data structures

;; Challenge details
(define-map challenges
  { challenge-id: uint }
  {
    name: (string-ascii 50),
    description: (string-ascii 200),
    creator: principal,
    start-block: uint,
    end-block: uint,
    entry-fee: uint,
    step-goal: uint,
    total-prize-pool: uint,
    is-active: bool,
    is-completed: bool,
    is-public: bool,
    max-participants: uint,
    participant-count: uint,
    rewards-distributed: bool
  }
)

;; Challenge rewards structure
(define-map challenge-rewards
  { challenge-id: uint }
  {
    first-place-percent: uint,
    second-place-percent: uint,
    third-place-percent: uint,
    participation-percent: uint
  }
)

;; Tracks users registered for a challenge
(define-map challenge-participants
  { challenge-id: uint, participant: principal }
  {
    registration-block: uint,
    total-steps: uint,
    last-submission-block: uint,
    qualified: bool
  }
)

;; Tracks daily step submissions
(define-map step-submissions
  { challenge-id: uint, participant: principal, day: uint }
  {
    steps: uint,
    submission-block: uint,
    verified: bool
  }
)

;; Authorized data providers (oracles)
(define-map data-providers
  { provider: principal }
  { authorized: bool }
)

;; Variable for challenge ID counter
(define-data-var next-challenge-id uint u1)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Private functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Check if sender is contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

;; Check if sender is authorized data provider
(define-private (is-data-provider)
  (default-to false (get authorized (map-get? data-providers { provider: tx-sender })))
)

;; Check if challenge exists
(define-private (challenge-exists (challenge-id uint))
  (is-some (map-get? challenges { challenge-id: challenge-id }))
)

;; Check if user is registered for a challenge
(define-private (is-participant (challenge-id uint) (user principal))
  (is-some (map-get? challenge-participants { challenge-id: challenge-id, participant: user }))
)

;; Calculate day number relative to challenge start
(define-private (get-challenge-day (challenge-id uint))
  (let (
    (challenge-data (unwrap! (map-get? challenges { challenge-id: challenge-id }) u0))
    (current-block block-height)
    (start-block (get start-block challenge-data))
    (blocks-per-day u144) ;; Approximately 144 blocks per day on Stacks
  )
  (if (< current-block start-block)
    u0
    (/ (- current-block start-block) blocks-per-day))
  )
)

;; Calculate percentage of total with precision
(define-private (calculate-percentage (amount uint) (percentage uint))
  (/ (* amount percentage) REWARD-PRECISION)
)

;; Check if a challenge is active
(define-private (is-challenge-active (challenge-id uint))
  (let (
    (challenge-data (unwrap! (map-get? challenges { challenge-id: challenge-id }) false))
  )
    (and (get is-active challenge-data) 
         (>= block-height (get start-block challenge-data))
         (<= block-height (get end-block challenge-data)))
  )
)

;; Check if a challenge is completed
(define-private (is-challenge-completed (challenge-id uint))
  (let (
    (challenge-data (unwrap! (map-get? challenges { challenge-id: challenge-id }) false))
  )
    (and (get is-active challenge-data)
         (> block-height (get end-block challenge-data)))
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Read-only functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Get challenge details
(define-read-only (get-challenge (challenge-id uint))
  (map-get? challenges { challenge-id: challenge-id })
)

;; Get participant information for a challenge
(define-read-only (get-participant-info (challenge-id uint) (participant principal))
  (map-get? challenge-participants { challenge-id: challenge-id, participant: participant })
)

;; Get participant's step submission for a specific day
(define-read-only (get-daily-steps (challenge-id uint) (participant principal) (day uint))
  (map-get? step-submissions { challenge-id: challenge-id, participant: participant, day: day })
)

;; Get challenge reward structure
(define-read-only (get-challenge-reward-structure (challenge-id uint))
  (map-get? challenge-rewards { challenge-id: challenge-id })
)

;; Check if a provider is authorized
(define-read-only (is-authorized-provider (provider principal))
  (default-to false (get authorized (map-get? data-providers { provider: provider })))
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Add or remove data provider
(define-public (set-data-provider (provider principal) (authorized bool))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (map-set data-providers { provider: provider } { authorized: authorized }))
  )
)

;; Create a new challenge
(define-public (create-challenge 
    (name (string-ascii 50))
    (description (string-ascii 200))
    (start-block uint)
    (end-block uint)
    (entry-fee uint)
    (step-goal uint)
    (is-public bool)
    (max-participants uint)
    (first-place-percent uint)
    (second-place-percent uint)
    (third-place-percent uint)
    (participation-percent uint)
  )
  (let (
    (challenge-id (var-get next-challenge-id))
  )
    ;; Input validation
    (asserts! (> (len name) u0) ERR-INVALID-PARAMETERS)
    (asserts! (>= start-block block-height) ERR-INVALID-PARAMETERS)
    (asserts! (> end-block start-block) ERR-INVALID-PARAMETERS)
    (asserts! (>= max-participants u2) ERR-INVALID-PARAMETERS)
    
    ;; Validate reward percentages add up to 100% (1,000,000 with precision)
    (asserts! 
      (is-eq (+ (+ (+ first-place-percent second-place-percent) third-place-percent) participation-percent) 
             REWARD-PRECISION) 
      ERR-INVALID-PARAMETERS)
    
    ;; Create challenge
    (map-set challenges 
      { challenge-id: challenge-id }
      {
        name: name,
        description: description,
        creator: tx-sender,
        start-block: start-block,
        end-block: end-block,
        entry-fee: entry-fee,
        step-goal: step-goal,
        total-prize-pool: u0,
        is-active: true,
        is-completed: false,
        is-public: is-public,
        max-participants: max-participants,
        participant-count: u0,
        rewards-distributed: false
      }
    )
    
    ;; Set reward structure
    (map-set challenge-rewards
      { challenge-id: challenge-id }
      {
        first-place-percent: first-place-percent,
        second-place-percent: second-place-percent,
        third-place-percent: third-place-percent,
        participation-percent: participation-percent
      }
    )
    
    ;; Update challenge counter
    (var-set next-challenge-id (+ challenge-id u1))
    
    (ok challenge-id)
  )
)

;; Register for a challenge
(define-public (register-for-challenge (challenge-id uint))
  (let (
    (challenge-data (unwrap! (map-get? challenges { challenge-id: challenge-id }) ERR-CHALLENGE-NOT-FOUND))
    (entry-fee (get entry-fee challenge-data))
    (participant-count (get participant-count challenge-data))
    (max-participants (get max-participants challenge-data))
  )
    ;; Check if challenge is still open for registration
    (asserts! (get is-active challenge-data) ERR-CHALLENGE-CLOSED)
    (asserts! (< block-height (get start-block challenge-data)) ERR-CHALLENGE-CLOSED)
    
    ;; Check if challenge is public or user is creator
    (asserts! (or (get is-public challenge-data) (is-eq tx-sender (get creator challenge-data))) 
              ERR-NOT-AUTHORIZED)
    
    ;; Check if maximum participants reached
    (asserts! (< participant-count max-participants) ERR-CHALLENGE-CLOSED)
    
    ;; Check if user is already registered
    (asserts! (not (is-participant challenge-id tx-sender)) ERR-USER-ALREADY-REGISTERED)
    
    ;; Handle entry fee
    (if (> entry-fee u0)
      (begin
        (try! (stx-transfer? entry-fee tx-sender (as-contract tx-sender)))
        ;; Update prize pool
        (map-set challenges 
          { challenge-id: challenge-id }
          (merge challenge-data { 
            total-prize-pool: (+ (get total-prize-pool challenge-data) entry-fee),
            participant-count: (+ participant-count u1)
          })
        )
      )
      ;; Just update participant count if no entry fee
      (map-set challenges 
        { challenge-id: challenge-id }
        (merge challenge-data { participant-count: (+ participant-count u1) })
      )
    )
    
    ;; Register participant
    (map-set challenge-participants
      { challenge-id: challenge-id, participant: tx-sender }
      {
        registration-block: block-height,
        total-steps: u0,
        last-submission-block: u0,
        qualified: true
      }
    )
    
    (ok true)
  )
)

;; Submit step count for a challenge (by authorized data provider)
(define-public (submit-steps (challenge-id uint) (participant principal) (steps uint))
  (let (
    (challenge-data (unwrap! (map-get? challenges { challenge-id: challenge-id }) ERR-CHALLENGE-NOT-FOUND))
    (day (get-challenge-day challenge-id))
    (participant-data (unwrap! (map-get? challenge-participants 
                                { challenge-id: challenge-id, participant: participant }) 
                                ERR-USER-NOT-REGISTERED))
  )
    ;; Check if sender is authorized data provider
    (asserts! (is-data-provider) ERR-NOT-DATA-PROVIDER)
    
    ;; Check if challenge is active
    (asserts! (is-challenge-active challenge-id) ERR-CHALLENGE-CLOSED)
    
    ;; Check if daily steps is within reasonable limit
    (asserts! (<= steps MAX-DAILY-STEPS) ERR-DAILY-STEP-LIMIT-EXCEEDED)
    
    ;; Check if steps have already been submitted for today
    (asserts! (is-none (map-get? step-submissions 
                        { challenge-id: challenge-id, participant: participant, day: day }))
              ERR-ALREADY-SUBMITTED-TODAY)
    
    ;; Record step submission for this day
    (map-set step-submissions
      { challenge-id: challenge-id, participant: participant, day: day }
      {
        steps: steps,
        submission-block: block-height,
        verified: true
      }
    )
    
    ;; Update participant's total steps
    (map-set challenge-participants
      { challenge-id: challenge-id, participant: participant }
      (merge participant-data {
        total-steps: (+ (get total-steps participant-data) steps),
        last-submission-block: block-height
      })
    )
    
    (ok true)
  )
)

;; Complete a challenge and prepare for reward distribution
(define-public (complete-challenge (challenge-id uint))
  (let (
    (challenge-data (unwrap! (map-get? challenges { challenge-id: challenge-id }) ERR-CHALLENGE-NOT-FOUND))
  )
    ;; Only creator or contract owner can complete the challenge
    (asserts! (or (is-eq tx-sender (get creator challenge-data)) (is-contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Challenge must be active but past end block
    (asserts! (is-challenge-completed challenge-id) ERR-CHALLENGE-NOT-COMPLETE)
    
    ;; Mark challenge as completed
    (map-set challenges
      { challenge-id: challenge-id }
      (merge challenge-data {
        is-active: false,
        is-completed: true
      })
    )
    
    (ok true)
  )
)

;; Distribute rewards for a completed challenge
(define-public (distribute-rewards (challenge-id uint))
  (let (
    (challenge-data (unwrap! (map-get? challenges { challenge-id: challenge-id }) ERR-CHALLENGE-NOT-FOUND))
    (reward-data (unwrap! (map-get? challenge-rewards { challenge-id: challenge-id }) ERR-CHALLENGE-NOT-FOUND))
  )
    ;; Only creator or contract owner can distribute rewards
    (asserts! (or (is-eq tx-sender (get creator challenge-data)) (is-contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Challenge must be completed
    (asserts! (get is-completed challenge-data) ERR-CHALLENGE-NOT-COMPLETE)
    
    ;; Check rewards haven't been distributed yet
    (asserts! (not (get rewards-distributed challenge-data)) ERR-CHALLENGE-CLOSED)
    
    ;; Mark rewards as distributed to prevent multiple distributions
    (map-set challenges
      { challenge-id: challenge-id }
      (merge challenge-data { rewards-distributed: true })
    )
    
    ;; Return success - actual distribution would require additional functions to calculate
    ;; rankings and distribute the appropriate rewards
    (ok true)
  )
)

;; Cancel a challenge (only before it starts)
(define-public (cancel-challenge (challenge-id uint))
  (let (
    (challenge-data (unwrap! (map-get? challenges { challenge-id: challenge-id }) ERR-CHALLENGE-NOT-FOUND))
  )
    ;; Only creator or contract owner can cancel
    (asserts! (or (is-eq tx-sender (get creator challenge-data)) (is-contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Challenge must not have started yet
    (asserts! (< block-height (get start-block challenge-data)) ERR-CHALLENGE-ACTIVE)
    
    ;; Mark challenge as inactive
    (map-set challenges
      { challenge-id: challenge-id }
      (merge challenge-data {
        is-active: false,
        is-completed: true
      })
    )
    
    ;; Return success - refund functionality would need to be implemented separately
    (ok true)
  )
)