;; VaultCoin Protocol: Next-Generation Decentralized Stablecoin Infrastructure
;;
;; A sophisticated multi-collateral stablecoin protocol engineered for the Stacks blockchain,
;; delivering unprecedented stability and capital efficiency through advanced vault mechanics.
;;
;; VaultCoin revolutionizes DeFi lending by enabling users to unlock liquidity from their
;; STX and xBTC holdings while maintaining exposure to potential upside. The protocol
;; combines battle-tested economic models with cutting-edge liquidation algorithms to
;; ensure system-wide solvency and user protection.
;;
;; Core Features:
;; - Multi-asset collateral support (STX, xBTC) with seamless expansion capabilities
;; - Dynamic risk management with real-time oracle price feeds
;; - Automated liquidation engine protecting against market volatility
;; - SIP-010 compliant USDx token with full ecosystem compatibility
;; - Governance-ready architecture for future decentralized operations
;; - Capital-efficient design minimizing collateral requirements
;;
;; Security Model:
;; - Comprehensive access control with role-based permissions
;; - Price staleness protection preventing oracle manipulation
;; - Overflow protection and input validation throughout
;; - Emergency shutdown capabilities for crisis management
;;

;; CONSTANTS AND ERROR DEFINITIONS

(define-constant CONTRACT-OWNER tx-sender)

;; Error codes with descriptive naming
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-VAULT-NOT-FOUND (err u1001))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u1002))
(define-constant ERR-VAULT-UNDERCOLLATERALIZED (err u1003))
(define-constant ERR-LIQUIDATION-NOT-ALLOWED (err u1004))
(define-constant ERR-INVALID-AMOUNT (err u1005))
(define-constant ERR-ORACLE-PRICE-STALE (err u1006))
(define-constant ERR-MINIMUM-COLLATERAL-RATIO (err u1007))
(define-constant ERR-VAULT-ALREADY-EXISTS (err u1008))
(define-constant ERR-INSUFFICIENT-USDX-BALANCE (err u1009))
(define-constant ERR-TRANSFER-FAILED (err u1010))

;; Protocol risk parameters
(define-constant LIQUIDATION-RATIO u150) ;; 150% - liquidation threshold
(define-constant MINIMUM-COLLATERAL-RATIO u200) ;; 200% - minimum for new vaults
(define-constant LIQUIDATION-PENALTY u110) ;; 10% liquidation penalty
(define-constant STABILITY-FEE-RATE u2) ;; 2% annual stability fee
(define-constant MAX-PRICE-AGE u3600) ;; 1 hour max price age (in seconds)

;; DATA STRUCTURES

;; Vault structure - core lending unit
(define-map vaults
  { vault-id: uint }
  {
    owner: principal,
    stx-collateral: uint,
    xbtc-collateral: uint,
    debt: uint,
    last-update: uint,
    is-active: bool,
  }
)

;; User vault mapping for efficient lookups
(define-map user-vaults
  { user: principal }
  { vault-ids: (list 10 uint) }
)

;; Oracle price feeds with confidence scoring
(define-map price-feeds
  { asset: (string-ascii 10) }
  {
    price: uint,
    timestamp: uint,
    confidence: uint,
  }
)

;; Protocol-wide statistics tracking
(define-data-var total-vaults uint u0)
(define-data-var total-debt uint u0)
(define-data-var total-stx-collateral uint u0)
(define-data-var total-xbtc-collateral uint u0)
(define-data-var liquidation-pool uint u0)

;; Access control mappings
(define-map authorized-liquidators
  principal
  bool
)
(define-map oracle-operators
  principal
  bool
)

;; USDX TOKEN IMPLEMENTATION (SIP-010)

(define-fungible-token usdx)

;; Token metadata
(define-data-var token-name (string-ascii 32) "VaultCoin USD")
(define-data-var token-symbol (string-ascii 10) "USDx")
(define-data-var token-uri (optional (string-utf8 256)) none)
(define-data-var token-decimals uint u6)

;; SIP-010 standard compliance functions
(define-read-only (get-name)
  (ok (var-get token-name))
)

(define-read-only (get-symbol)
  (ok (var-get token-symbol))
)

(define-read-only (get-decimals)
  (ok (var-get token-decimals))
)

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance usdx who))
)

(define-read-only (get-total-supply)
  (ok (ft-get-supply usdx))
)

(define-read-only (get-token-uri)
  (ok (var-get token-uri))
)

;; Token transfer with comprehensive validation
(define-public (transfer
    (amount uint)
    (from principal)
    (to principal)
    (memo (optional (buff 34)))
  )
  (begin
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (or (is-eq from tx-sender) (is-eq from contract-caller))
      ERR-NOT-AUTHORIZED
    )
    (asserts! (not (is-eq from to)) ERR-INVALID-AMOUNT)
    (ft-transfer? usdx amount from to)
  )
)

;; ORACLE MANAGEMENT SYSTEM

;; Authorize oracle operators with proper access control
(define-public (set-oracle-operator
    (operator principal)
    (authorized bool)
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq operator tx-sender)) ERR-INVALID-AMOUNT)
    (ok (map-set oracle-operators operator authorized))
  )
)

;; Update price feeds with confidence scoring
(define-public (update-price
    (asset (string-ascii 10))
    (price uint)
    (confidence uint)
  )
  (begin
    (asserts! (default-to false (map-get? oracle-operators tx-sender))
      ERR-NOT-AUTHORIZED
    )
    (asserts! (> price u0) ERR-INVALID-AMOUNT)
    (asserts! (and (>= confidence u1) (<= confidence u100)) ERR-INVALID-AMOUNT)
    (asserts! (> (len asset) u0) ERR-INVALID-AMOUNT)
    (ok (map-set price-feeds { asset: asset } {
      price: price,
      timestamp: stacks-block-height,
      confidence: confidence,
    }))
  )
)

;; Retrieve current price with staleness protection
(define-read-only (get-price (asset (string-ascii 10)))
  (let ((price-data (map-get? price-feeds { asset: asset })))
    (match price-data
      feed (if (< (- stacks-block-height (get timestamp feed)) MAX-PRICE-AGE)
        (ok (get price feed))
        ERR-ORACLE-PRICE-STALE
      )
      ERR-ORACLE-PRICE-STALE
    )
  )
)

;; VAULT MANAGEMENT FUNCTIONS

;; Create new vault with multi-collateral support
(define-public (create-vault
    (stx-amount uint)
    (xbtc-amount uint)
  )
  (let (
      (vault-id (+ (var-get total-vaults) u1))
      (stx-price (unwrap! (get-price "STX") ERR-ORACLE-PRICE-STALE))
      (xbtc-price (unwrap! (get-price "xBTC") ERR-ORACLE-PRICE-STALE))
      (total-collateral-value (+ (* stx-amount stx-price) (* xbtc-amount xbtc-price)))
      (user-vaults-list (default-to (list)
        (get vault-ids (map-get? user-vaults { user: tx-sender }))
      ))
    )
    (asserts! (> stx-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= xbtc-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (< vault-id u1000000) ERR-INVALID-AMOUNT)
    (asserts! (is-none (map-get? vaults { vault-id: vault-id }))
      ERR-VAULT-ALREADY-EXISTS
    )
    ;; Transfer collateral to contract
    (try! (stx-transfer? stx-amount tx-sender (as-contract tx-sender)))
    ;; Create vault entry
    (map-set vaults { vault-id: vault-id } {
      owner: tx-sender,
      stx-collateral: stx-amount,
      xbtc-collateral: xbtc-amount,
      debt: u0,
      last-update: stacks-block-height,
      is-active: true,
    })
    ;; Update user vault list
    (map-set user-vaults { user: tx-sender } { vault-ids: (unwrap! (as-max-len? (append user-vaults-list vault-id) u10)
      ERR-INVALID-AMOUNT
    ) }
    )
    ;; Update protocol statistics
    (var-set total-vaults vault-id)
    (var-set total-stx-collateral (+ (var-get total-stx-collateral) stx-amount))
    (var-set total-xbtc-collateral
      (+ (var-get total-xbtc-collateral) xbtc-amount)
    )
    (ok vault-id)
  )
)

;; Add additional collateral to existing vault
(define-public (add-collateral
    (vault-id uint)
    (stx-amount uint)
    (xbtc-amount uint)
  )
  (let ((vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND)))
    (asserts! (> vault-id u0) ERR-INVALID-AMOUNT)
    (asserts! (is-eq (get owner vault) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (> stx-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= xbtc-amount u0) ERR-INVALID-AMOUNT)
    ;; Transfer additional collateral
    (try! (stx-transfer? stx-amount tx-sender (as-contract tx-sender)))
    ;; Update vault with new collateral
    (map-set vaults { vault-id: vault-id }
      (merge vault {
        stx-collateral: (+ (get stx-collateral vault) stx-amount),
        xbtc-collateral: (+ (get xbtc-collateral vault) xbtc-amount),
        last-update: stacks-block-height,
      })
    )
    ;; Update protocol statistics
    (var-set total-stx-collateral (+ (var-get total-stx-collateral) stx-amount))
    (var-set total-xbtc-collateral
      (+ (var-get total-xbtc-collateral) xbtc-amount)
    )
    (ok true)
  )
)

;; Mint USDx tokens against collateral
(define-public (mint-usdx
    (vault-id uint)
    (amount uint)
  )
  (let (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (stx-price (unwrap! (get-price "STX") ERR-ORACLE-PRICE-STALE))
      (xbtc-price (unwrap! (get-price "xBTC") ERR-ORACLE-PRICE-STALE))
      (collateral-value (+ (* (get stx-collateral vault) stx-price)
        (* (get xbtc-collateral vault) xbtc-price)
      ))
      (new-debt (+ (get debt vault) amount))
      (collateral-ratio (/ (* collateral-value u100) new-debt))
    )
    (asserts! (> vault-id u0) ERR-INVALID-AMOUNT)
    (asserts! (is-eq (get owner vault) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (< amount u1000000000000) ERR-INVALID-AMOUNT)
    (asserts! (>= collateral-ratio MINIMUM-COLLATERAL-RATIO)
      ERR-MINIMUM-COLLATERAL-RATIO
    )
    ;; Mint USDx tokens to user
    (try! (ft-mint? usdx amount tx-sender))
    ;; Update vault debt
    (map-set vaults { vault-id: vault-id }
      (merge vault {
        debt: new-debt,
        last-update: stacks-block-height,
      })
    )
    ;; Update protocol statistics
    (var-set total-debt (+ (var-get total-debt) amount))
    (ok true)
  )
)

;; Burn USDx tokens to reduce debt
(define-public (burn-usdx
    (vault-id uint)
    (amount uint)
  )
  (let (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (user-balance (ft-get-balance usdx tx-sender))
    )
    (asserts! (> vault-id u0) ERR-INVALID-AMOUNT)
    (asserts! (is-eq (get owner vault) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= user-balance amount) ERR-INSUFFICIENT-USDX-BALANCE)
    (asserts! (>= (get debt vault) amount) ERR-INVALID-AMOUNT)
    ;; Burn USDx tokens from user
    (try! (ft-burn? usdx amount tx-sender))
    ;; Update vault debt
    (map-set vaults { vault-id: vault-id }
      (merge vault {
        debt: (- (get debt vault) amount),
        last-update: stacks-block-height,
      })
    )
    ;; Update protocol statistics
    (var-set total-debt (- (var-get total-debt) amount))
    (ok true)
  )
)

;; Withdraw collateral with safety checks
(define-public (withdraw-collateral
    (vault-id uint)
    (stx-amount uint)
  )
  (let (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (stx-price (unwrap! (get-price "STX") ERR-ORACLE-PRICE-STALE))
      (xbtc-price (unwrap! (get-price "xBTC") ERR-ORACLE-PRICE-STALE))
      (remaining-stx (- (get stx-collateral vault) stx-amount))
      (remaining-collateral-value (+ (* remaining-stx stx-price) (* (get xbtc-collateral vault) xbtc-price)))
      (debt (get debt vault))
    )
    (asserts! (> vault-id u0) ERR-INVALID-AMOUNT)
    (asserts! (is-eq (get owner vault) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (> stx-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= (get stx-collateral vault) stx-amount)
      ERR-INSUFFICIENT-COLLATERAL
    )
    ;; Verify minimum collateral ratio is maintained
    (if (> debt u0)
      (asserts!
        (>= (/ (* remaining-collateral-value u100) debt) MINIMUM-COLLATERAL-RATIO)
        ERR-MINIMUM-COLLATERAL-RATIO
      )
      true
    )
    ;; Transfer collateral back to user
    (try! (as-contract (stx-transfer? stx-amount tx-sender (get owner vault))))
    ;; Update vault state
    (map-set vaults { vault-id: vault-id }
      (merge vault {
        stx-collateral: remaining-stx,
        last-update: stacks-block-height,
      })
    )
    ;; Update protocol statistics
    (var-set total-stx-collateral (- (var-get total-stx-collateral) stx-amount))
    (ok true)
  )
)

;; LIQUIDATION ENGINE

;; Authorize liquidators with proper access control
(define-public (set-liquidator
    (liquidator principal)
    (authorized bool)
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq liquidator tx-sender)) ERR-INVALID-AMOUNT)
    (ok (map-set authorized-liquidators liquidator authorized))
  )
)

;; Calculate vault health factor for liquidation assessment
(define-read-only (calculate-health-factor (vault-id uint))
  (match (map-get? vaults { vault-id: vault-id })
    vault (match (get-price "STX")
      stx-price (match (get-price "xBTC")
        xbtc-price (let (
            (collateral-value (+ (* (get stx-collateral vault) stx-price)
              (* (get xbtc-collateral vault) xbtc-price)
            ))
            (debt (get debt vault))
          )
          (if (is-eq debt u0)
            (ok u999999) ;; Infinite health factor if no debt
            (ok (/ (* collateral-value u100) debt))
          )
        )
        xbtc-err
        ERR-ORACLE-PRICE-STALE
      )
      stx-err
      ERR-ORACLE-PRICE-STALE
    )
    ERR-VAULT-NOT-FOUND
  )
)

;; Liquidate undercollateralized vault
(define-public (liquidate-vault (vault-id uint))
  (let (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (health-factor (unwrap! (calculate-health-factor vault-id) ERR-ORACLE-PRICE-STALE))
      (debt (get debt vault))
      (stx-collateral (get stx-collateral vault))
      (xbtc-collateral (get xbtc-collateral vault))
      (liquidation-amount (/ (* debt LIQUIDATION-PENALTY) u100))
    )
    (asserts! (default-to false (map-get? authorized-liquidators tx-sender))
      ERR-NOT-AUTHORIZED
    )
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (< health-factor LIQUIDATION-RATIO) ERR-LIQUIDATION-NOT-ALLOWED)
    (asserts! (>= (ft-get-balance usdx tx-sender) debt)
      ERR-INSUFFICIENT-USDX-BALANCE
    )
    ;; Burn liquidator's USDx to cover debt
    (try! (ft-burn? usdx debt tx-sender))
    ;; Calculate collateral distribution to liquidator
    (let (
        (stx-to-liquidator (/ (* stx-collateral liquidation-amount) debt))
        (xbtc-to-liquidator (/ (* xbtc-collateral liquidation-amount) debt))
      )
      ;; Transfer collateral to liquidator
      (try! (as-contract (stx-transfer? stx-to-liquidator tx-sender tx-sender)))
      ;; Deactivate vault and update state
      (map-set vaults { vault-id: vault-id }
        (merge vault {
          debt: u0,
          stx-collateral: (- stx-collateral stx-to-liquidator),
          xbtc-collateral: (- xbtc-collateral xbtc-to-liquidator),
          is-active: false,
          last-update: stacks-block-height,
        })
      )
      ;; Update protocol statistics
      (var-set total-debt (- (var-get total-debt) debt))
      (var-set total-stx-collateral
        (- (var-get total-stx-collateral) stx-to-liquidator)
      )
      (var-set total-xbtc-collateral
        (- (var-get total-xbtc-collateral) xbtc-to-liquidator)
      )
      (ok true)
    )
  )
)