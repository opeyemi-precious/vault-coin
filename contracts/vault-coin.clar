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