(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-listed (err u102))
(define-constant err-insufficient-funds (err u103))
(define-constant err-expired (err u104))
(define-constant err-not-available (err u105))

(define-data-var min-bid uint u1000000)
(define-data-var listing-fee uint u100000)

(define-map satellites 
    { satellite-id: uint }
    {
        owner: principal,
        available: bool,
        base-price: uint,
        bandwidth: uint,
        current-tenant: (optional principal),
        lease-end: uint
    }
)

(define-map bids
    { satellite-id: uint, bidder: principal }
    { amount: uint, expires: uint }
)

(define-map bandwidth-licenses
    { satellite-id: uint, owner: principal }
    {
        bandwidth-amount: uint,
        expires: uint,
        price-paid: uint
    }
)

(define-map bandwidth-adjustments
    { satellite-id: uint, tenant: principal }
    {
        proposed-bandwidth: uint,
        status: (optional bool)
    }
)

(define-public (register-satellite (satellite-id uint) (base-price uint) (bandwidth uint))
    (let
        ((satellite-data {
            owner: tx-sender,
            available: true,
            base-price: base-price,
            bandwidth: bandwidth,
            current-tenant: none,
            lease-end: u0
        }))
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (map-insert satellites { satellite-id: satellite-id } satellite-data))
    )
)

(define-public (place-bid (satellite-id uint) (bid-amount uint))
    (let
        ((satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found))

         (expires (+ burn-block-height u144)))
        (asserts! (>= bid-amount (var-get min-bid)) err-insufficient-funds)
        (asserts! (get available satellite) err-not-available)
        (ok (map-set bids
            { satellite-id: satellite-id, bidder: tx-sender }
            { amount: bid-amount, expires: expires }))
    )
)

(define-public (cancel-bid (satellite-id uint))
    (let
        ((bid (unwrap! (map-get? bids { satellite-id: satellite-id, bidder: tx-sender }) err-not-found)))
        (ok (map-delete bids { satellite-id: satellite-id, bidder: tx-sender }))
    )
)

(define-public (accept-bid (satellite-id uint) (bidder principal))
    (let
        ((bid (unwrap! (map-get? bids { satellite-id: satellite-id, bidder: bidder }) err-not-found))
         (satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found))
         (lease-period u4320))
        (asserts! (is-eq (get owner satellite) tx-sender) err-owner-only)

        (asserts! (<= burn-block-height (get expires bid)) err-expired)
        
        (try! (stx-transfer? (get amount bid) bidder (get owner satellite)))
        
        (map-set satellites { satellite-id: satellite-id }
            (merge satellite {
                available: false,
                current-tenant: (some bidder),

                lease-end: (+ burn-block-height lease-period)
            })
        )
        
        (map-set bandwidth-licenses
            { satellite-id: satellite-id, owner: bidder }
            {
                bandwidth-amount: (get bandwidth satellite),

                expires: (+ burn-block-height lease-period),
                price-paid: (get amount bid)
            }
        )
        (ok true)
    )
)

(define-public (end-lease (satellite-id uint))
     (let
         ((satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found)))
         (asserts! (is-eq (some tx-sender) (get current-tenant satellite)) err-owner-only)



         (asserts! (>= burn-block-height (get lease-end satellite)) (err u403))

         (map-set satellites { satellite-id: satellite-id }
             (merge satellite {
                 available: true,
                 current-tenant: none,
                 lease-end: u0
             })
         )
         (ok true)
     )
 )

(define-public (renew-lease (satellite-id uint) (extension-period uint))
     (let
         ((satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found))
          (license (unwrap! (map-get? bandwidth-licenses { satellite-id: satellite-id, owner: tx-sender }) err-not-found))
          (remaining-blocks (- (get lease-end satellite) burn-block-height))
          (prorated-payment (/ (* (get base-price satellite) extension-period) u4320)))
         (asserts! (is-eq (some tx-sender) (get current-tenant satellite)) err-owner-only)
         (asserts! (> remaining-blocks u0) err-expired)
         (try! (stx-transfer? prorated-payment tx-sender (get owner satellite)))
         (map-set satellites { satellite-id: satellite-id }
             (merge satellite { lease-end: (+ (get lease-end satellite) extension-period) })
         )
         (map-set bandwidth-licenses
             { satellite-id: satellite-id, owner: tx-sender }
             (merge license { expires: (+ (get expires license) extension-period) })
         )
         (ok true)
     )
 )

(define-public (transfer-satellite-ownership (satellite-id uint) (new-owner principal))
    (let
        ((satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found)))
        (asserts! (is-eq tx-sender (get owner satellite)) err-owner-only)
        (map-set satellites { satellite-id: satellite-id }
            (merge satellite { owner: new-owner })
        )
        (ok true)
    )
)

(define-read-only (get-satellite-info (satellite-id uint))
    (ok (map-get? satellites { satellite-id: satellite-id }))
)

(define-read-only (get-bid-info (satellite-id uint) (bidder principal))
    (ok (map-get? bids { satellite-id: satellite-id, bidder: bidder }))
)

(define-public (check-and-release-expired-satellite (satellite-id uint))
    (let
        ((satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found)))
        (if (and (not (get available satellite)) 
                 (> burn-block-height (get lease-end satellite))
                 (> (get lease-end satellite) u0))
            (begin
                (map-set satellites { satellite-id: satellite-id }
                    (merge satellite {
                        available: true,
                        current-tenant: none,
                        lease-end: u0
                    })
                )
                (ok true)
            )
            (ok false)
        )
    )
)

(define-read-only (get-license-info (satellite-id uint) (owner principal))
    (ok (map-get? bandwidth-licenses { satellite-id: satellite-id, owner: owner }))
)

(define-public (request-bandwidth-adjustment (satellite-id uint) (proposed-bandwidth uint))
    (let
        ((satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found))
         (license (unwrap! (map-get? bandwidth-licenses { satellite-id: satellite-id, owner: tx-sender }) err-not-found)))
        (asserts! (is-eq (some tx-sender) (get current-tenant satellite)) err-owner-only)
        (asserts! (<= proposed-bandwidth (get bandwidth satellite)) err-insufficient-funds)
        (asserts! (> burn-block-height (get expires license)) err-expired)
        (ok (map-set bandwidth-adjustments
            { satellite-id: satellite-id, tenant: tx-sender }
            { proposed-bandwidth: proposed-bandwidth, status: none }))
    )
)

(define-public (approve-bandwidth-adjustment (satellite-id uint) (tenant principal))
    (let
        ((adjustment (unwrap! (map-get? bandwidth-adjustments { satellite-id: satellite-id, tenant: tenant }) err-not-found))
         (satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found))
         (license (unwrap! (map-get? bandwidth-licenses { satellite-id: satellite-id, owner: tenant }) err-not-found)))
        (asserts! (is-eq tx-sender (get owner satellite)) err-owner-only)
        (asserts! (is-none (get status adjustment)) err-already-listed)
        (map-set bandwidth-licenses
            { satellite-id: satellite-id, owner: tenant }
            (merge license { bandwidth-amount: (get proposed-bandwidth adjustment) })
        )
        (map-set bandwidth-adjustments
            { satellite-id: satellite-id, tenant: tenant }
            (merge adjustment { status: (some true) })
        )
        (ok true)
    )
)

(define-public (reject-bandwidth-adjustment (satellite-id uint) (tenant principal))
    (let
        ((adjustment (unwrap! (map-get? bandwidth-adjustments { satellite-id: satellite-id, tenant: tenant }) err-not-found))
         (satellite (unwrap! (map-get? satellites { satellite-id: satellite-id }) err-not-found)))
        (asserts! (is-eq tx-sender (get owner satellite)) err-owner-only)
        (asserts! (is-none (get status adjustment)) err-already-listed)
        (map-set bandwidth-adjustments
            { satellite-id: satellite-id, tenant: tenant }
            (merge adjustment { status: (some false) })
        )
        (ok true)
    )
)

(define-read-only (get-bandwidth-adjustment (satellite-id uint) (tenant principal))
    (ok (map-get? bandwidth-adjustments { satellite-id: satellite-id, tenant: tenant }))
)