// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAutoJob} from "./IAutoJob.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PeekRegistry - PeekPeak's autonomous execution registry.
/// @notice Immutable, versioned registry (SPEC-2 D2). Holds per-job native-coin
///         escrows, dispatches `performJob` to authorized executors, reimburses
///         executor gas and routes a flat keeper tip to the protocol treasury
///         (DIV-D-3; no percentage premium exists).
/// @dev Pricing (DIV-D-3): every SUCCESSFUL execution charges exact gas
///      reimbursement (gasUsed * tx.gasprice) plus a flat keeper tip (default
///      0.005 AVAX) routed to the treasury. Failed or reverting executions
///      charge nothing; checkJob statics are always free.
///      Escrow accounting per SPEC-5: checks-effects-interactions inside
///      `nonReentrant`; all arithmetic on uint256 before narrowing casts (RULE-6);
///      native payouts via checked `call{value}` only - never `transfer()` (RULE-5).
///      A target that reverts never charges the client and never pays the executor
///      (RULE-4); the failure counter persists because the registry transaction
///      itself succeeds (DIV-D-1).
contract PeekRegistry is Ownable, ReentrancyGuard {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice Job parameters. Occupies exactly two storage slots (RULE-7):
    ///         slot A = target (20) | gasLimit (4) | isActive (1) | consecutiveReverts (1) + 6 pad
    ///         slot B = owner (20) | maxGasPriceGwei (8) + 4 pad
    struct Job {
        // --- slot A (32 bytes: 26 used, 6 padding) ---
        address target;
        uint32 gasLimit;
        bool isActive;
        uint8 consecutiveReverts;
        // --- slot B (32 bytes: 28 used, 4 padding) ---
        address owner;
        uint64 maxGasPriceGwei;
    }

    enum JobStopReason {
        Depleted,
        Reverting
    }

    // ------------------------------------------------------------------
    // Constants & immutables
    // ------------------------------------------------------------------

    uint32 public constant MAX_JOB_GAS_LIMIT = 2_500_000;
    /// @notice Upper bound for the owner-settable keeper tip (10x default).
    uint128 public constant MAX_KEEPER_TIP = 0.05 ether;
    /// @notice Flat execution tip charged on top of exact gas reimbursement
    ///         (default; owner-adjustable within MAX_KEEPER_TIP).
    uint128 public constant DEFAULT_KEEPER_TIP = 0.005 ether;
    uint64 public constant MIN_MAX_GAS_PRICE_GWEI = 25;
    uint8 public constant MAX_REVERT_LIMIT = 10;
    uint32 public constant MIN_OVERHEAD_BUFFER = 10_000;
    /// @notice Upper bound for the deploy-time OVERHEAD_BUFFER (audit F-4):
    ///         10x the calibrated 50,000-gas default. A fat-fingered buffer
    ///         would overcharge escrows silently; this bound makes
    ///         misconfiguration fail loud at deployment.
    uint32 public constant MAX_OVERHEAD_BUFFER = 500_000;
    /// @notice Hard cap on the execPayload forwarded to a target (audit F-2 /
    ///         DIV-D-4). The calldata->memory copy of the payload is charged
    ///         inside executeJob's measured window but is not part of the
    ///         solvency model; an unbounded payload could push gasUsed past
    ///         the prechecked `gasLimit + 2*OVERHEAD_BUFFER` bound. 4 KB keeps
    ///         copy+expansion (~2.3k gas) well inside the MIN_OVERHEAD_BUFFER
    ///         slack, preserving the bound for every allowed buffer, while
    ///         remaining far above any legitimate keeper payload (the
    ///         reference adapter forwards ""). The worker's own broadcast gas
    ///         cap is no longer load-bearing for this invariant.
    uint256 public constant MAX_EXEC_PAYLOAD = 4_096;

    /// @notice Extra gas (beyond measured consumption) charged to the escrow to
    ///         cover the registry's post-measurement tail: escrow SSTORE, counter
    ///         reset, value transfers, and the success event. Calibrated by fork
    ///         tests (SPEC-5.5); expected range 28,000-35,000.
    uint32 public immutable OVERHEAD_BUFFER;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @dev jobId => Job. jobId = keccak256(abi.encode(target, owner, nonce)) (SPEC-4).
    mapping(bytes32 => Job) public jobs;
    /// @dev jobId => escrow in wei. Kept outside the Job struct (SPEC-2 D5, RULE-7).
    mapping(bytes32 => uint128) public escrows;
    mapping(address => bool) public authorizedExecutors;
    /// @dev Failed executor refunds parked for pull-over-push withdrawal (RULE-5).
    mapping(address => uint256) public pendingPull;

    address payable public treasury;
    /// @notice Flat keeper tip (wei) charged per successful execution, on top
    ///         of exact gas reimbursement. Routed to the treasury.
    uint128 public keeperTip;
    uint32 public maxConsecutiveReverts;
    bool public paused;
    uint256 public jobNonce;

    // ------------------------------------------------------------------
    // Events (RULE-8 - the worker only trusts these + storage reads)
    // ------------------------------------------------------------------

    event JobRegistered(
        bytes32 indexed jobId, address indexed target, address indexed owner,
        uint32 gasLimit, uint64 maxGasPriceGwei, uint256 escrowDeposited
    );
    event GasDeposited(bytes32 indexed jobId, uint256 amount, uint128 newBalance);
    event GasWithdrawn(bytes32 indexed jobId, address indexed owner, uint256 amount);
    event JobStatusSet(bytes32 indexed jobId, bool isActive);
    event JobDeactivated(bytes32 indexed jobId, JobStopReason reason);
    event JobExecuted(
        bytes32 indexed jobId, address indexed executor,
        uint256 gasUsed, uint256 baseExecutionCost, uint256 keeperTip
    );
    event TargetReverted(bytes32 indexed jobId, address indexed executor, uint256 consecutiveReverts);
    event ExecutorSet(address indexed executor, bool authorized);
    event TreasurySet(address indexed treasury);
    event KeeperTipSet(uint128 keeperTip);
    event MaxRevertsSet(uint32 maxConsecutiveReverts);
    event PausedSet(bool paused);
    event PullPending(address indexed executor, uint256 amount);
    event PullWithdrawn(address indexed executor, uint256 amount);

    // ------------------------------------------------------------------
    // Errors (RULE-9)
    // ------------------------------------------------------------------

    error UnauthorizedExecutor();
    error Paused();
    error JobNotFound();
    error JobInactive();
    error GasPriceExceedsJobCeiling();
    error InsufficientEscrow();
    error InsufficientEscrowDeposit();
    error NotJobOwner();
    error TransferFailed();
    error TreasuryTransferFailed();
    error InvalidTarget();
    error InvalidTreasury();
    error InvalidOverheadBuffer();
    error PayloadTooLarge();
    error GasLimitOutOfBounds();
    error GasPriceCeilingTooLow();
    error TipOutOfBounds();
    error RevertLimitOutOfBounds();
    error ZeroDeposit();
    error NothingToPull();
    error EscrowOverflow();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(
        address initialOwner,
        address payable initialTreasury,
        uint32 overheadBuffer,
        uint128 initialKeeperTip
    ) Ownable(initialOwner) {
        if (initialTreasury == address(0)) revert InvalidTreasury();
        if (overheadBuffer < MIN_OVERHEAD_BUFFER || overheadBuffer > MAX_OVERHEAD_BUFFER) {
            revert InvalidOverheadBuffer();
        }
        if (initialKeeperTip > MAX_KEEPER_TIP) revert TipOutOfBounds();
        treasury = initialTreasury;
        // 0 => chain-default tip; otherwise the deployment's own native
        // denomination (each L1's gas token has a different unit value)
        keeperTip = initialKeeperTip == 0 ? DEFAULT_KEEPER_TIP : initialKeeperTip;
        maxConsecutiveReverts = 3;
        OVERHEAD_BUFFER = overheadBuffer;
    }

    // ------------------------------------------------------------------
    // Registration & escrow lifecycle (SPEC-6)
    // ------------------------------------------------------------------

    /// @notice Register a job and pre-fund its escrow in one step.
    /// @dev `msg.value` must cover at least one worst-case execution so that
    ///      dead jobs cannot pollute the worker's polling set (anti-spam).
    function registerJob(
        address target,
        uint32 gasLimit,
        uint64 maxGasPriceGwei
    ) external payable returns (bytes32 jobId) {
        if (paused) revert Paused();
        if (target == address(0)) revert InvalidTarget();
        if (gasLimit == 0 || gasLimit > MAX_JOB_GAS_LIMIT) revert GasLimitOutOfBounds();
        if (maxGasPriceGwei < MIN_MAX_GAS_PRICE_GWEI) revert GasPriceCeilingTooLow();
        if (msg.value > type(uint128).max) revert EscrowOverflow();

        uint256 required = _worstCaseCost(gasLimit, tx.gasprice);
        if (msg.value < required) revert InsufficientEscrowDeposit();

        jobId = keccak256(abi.encode(target, msg.sender, jobNonce));
        jobNonce = jobNonce + 1;
        jobs[jobId] = Job({
            target: target,
            gasLimit: gasLimit,
            isActive: true,
            consecutiveReverts: 0,
            owner: msg.sender,
            maxGasPriceGwei: maxGasPriceGwei
        });
        escrows[jobId] = uint128(msg.value);
        emit JobRegistered(jobId, target, msg.sender, gasLimit, maxGasPriceGwei, msg.value);
    }

    /// @notice Top up a job's escrow with native coin.
    function depositGas(bytes32 jobId) external payable {
        if (jobs[jobId].target == address(0)) revert JobNotFound();
        if (msg.value == 0) revert ZeroDeposit();
        uint256 newBalance = uint256(escrows[jobId]) + msg.value;
        if (newBalance > type(uint128).max) revert EscrowOverflow();
        escrows[jobId] = uint128(newBalance);
        emit GasDeposited(jobId, msg.value, uint128(newBalance));
    }

    /// @notice Withdraw escrowed native coin. Job owner only.
    /// @dev Payout is pushed via checked `call{value}` and reverts on failure
    ///      (audit F-6): a rejecting wallet leaves the escrow in place for a
    ///      later retry, and a wallet that can NEVER receive native coin could
    ///      not use a pull fallback either (pull() transfers the same way).
    ///      Integrators must register from an EOA or an ETH-accepting contract
    ///      (SKILL.md rule 8).
    function withdrawGas(bytes32 jobId, uint128 amount) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.target == address(0)) revert JobNotFound();
        if (msg.sender != job.owner) revert NotJobOwner();
        uint128 balance = escrows[jobId];
        if (amount > balance) revert InsufficientEscrow();
        escrows[jobId] = balance - amount;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit GasWithdrawn(jobId, msg.sender, amount);
    }

    /// @notice Pause or resume a job. Job owner only.
    function setJobStatus(bytes32 jobId, bool isActive) external {
        Job storage job = jobs[jobId];
        if (job.target == address(0)) revert JobNotFound();
        if (msg.sender != job.owner) revert NotJobOwner();
        job.isActive = isActive;
        emit JobStatusSet(jobId, isActive);
    }

    // ------------------------------------------------------------------
    // Execution (SPEC-5)
    // ------------------------------------------------------------------

    /// @notice Execute a job whose `checkJob` returned true.
    /// @dev Authorized executors only. The caller forwards `job.gasLimit` gas to
    ///      the target; the outer transaction must carry `gasLimit + 2*OVERHEAD_BUFFER`
    ///      of headroom. Gas accounting:
    ///        gasUsed = (gasInitial - gasleft()) + OVERHEAD_BUFFER
    ///        baseExecutionCost = gasUsed * tx.gasprice
    ///        keeperTip = flat tip (default 0.005 AVAX), routed to treasury
    ///      Failure semantics (DIV-D-1): a depleted or reverting job soft-exits so
    ///      protective state changes persist - the client is never charged and the
    ///      executor is never reimbursed for failed work. The executor's own
    ///      transaction gas is the only loss, and only authorized executors (whose
    ///      watcher pre-simulates with eth_estimateGas) reach this path.
    ///      Trust model (audit F-7): nothing on-chain verifies checkJob before
    ///      dispatch (SPEC-3 gates off-chain), and each execution pays
    ///      gasUsed*tx.gasprice + keeperTip from the escrow. A compromised
    ///      authorized executor can therefore grind an escrow down to the
    ///      deactivation threshold with arbitrary payloads - bounded economic
    ///      and liveness loss, never principal loss beyond earned fees; client
    ///      recourse is withdrawGas/setJobStatus. Idempotent targets (RULE-12)
    ///      keep repeated pokes harmless. Executor keys stay hot-wallet-capped
    ///      (SPEC-2 D3, SEC-12).
    function executeJob(bytes32 jobId, bytes calldata execPayload) external nonReentrant {
        uint256 gasInitial = gasleft();

        // --- checks ---
        if (!authorizedExecutors[msg.sender]) revert UnauthorizedExecutor();
        if (paused) revert Paused();
        Job storage job = jobs[jobId];
        if (job.target == address(0)) revert JobNotFound();
        if (!job.isActive) revert JobInactive();
        if (tx.gasprice > uint256(job.maxGasPriceGwei) * 1 gwei) revert GasPriceExceedsJobCeiling();
        // DIV-D-4 (audit F-2): the payload's calldata->memory copy is charged
        // inside the measured window; bound it so gasUsed provably stays
        // within gasLimit + 2*OVERHEAD_BUFFER (see MAX_EXEC_PAYLOAD).
        if (execPayload.length > MAX_EXEC_PAYLOAD) revert PayloadTooLarge();

        uint128 escrow = escrows[jobId];
        if (escrow < _worstCaseCost(job.gasLimit, tx.gasprice)) {
            job.isActive = false;
            emit JobDeactivated(jobId, JobStopReason.Depleted);
            return;
        }

        // --- interaction (target may consume at most gasLimit) ---
        (bool ok,) = job.target.call{gas: job.gasLimit}(abi.encodeCall(IAutoJob.performJob, execPayload));

        // --- effects for the failure path: persist counter, never charge anyone ---
        if (!ok) {
            uint256 count = job.consecutiveReverts + 1;
            job.consecutiveReverts = uint8(count);
            emit TargetReverted(jobId, msg.sender, count);
            if (count >= maxConsecutiveReverts) {
                job.isActive = false;
                emit JobDeactivated(jobId, JobStopReason.Reverting);
            }
            return;
        }

        // --- effects for the success path: measure, charge escrow exactly once ---
        uint256 gasUsed = (gasInitial - gasleft()) + OVERHEAD_BUFFER;
        uint256 baseExecutionCost = gasUsed * tx.gasprice;
        uint256 tip = keeperTip;
        uint256 totalDeduction = baseExecutionCost + tip;

        // Defensive shortfall check against the CURRENT escrow, not the
        // pre-call snapshot (audit F-1): the target may have re-entered the
        // unguarded, additive-only depositGas() during performJob, so the
        // local `escrow` read at line "uint128 escrow = escrows[jobId]" can
        // be stale. While the solvency precheck, the payload cap (DIV-D-4)
        // and gasUsed <= gasLimit + 2*OVERHEAD_BUFFER hold, this branch is
        // unreachable; fail closed regardless.
        uint256 currentEscrow = escrows[jobId];
        if (currentEscrow < totalDeduction) {
            job.isActive = false;
            emit JobDeactivated(jobId, JobStopReason.Depleted);
            return;
        }

        escrows[jobId] = uint128(currentEscrow - totalDeduction);
        job.consecutiveReverts = 0;
        emit JobExecuted(jobId, msg.sender, gasUsed, baseExecutionCost, tip);

        // --- interactions: payouts after all effects (RULE-5) ---
        (bool refundOk,) = payable(msg.sender).call{value: baseExecutionCost}("");
        if (!refundOk) {
            pendingPull[msg.sender] += baseExecutionCost;
            emit PullPending(msg.sender, baseExecutionCost);
        }
        (bool treasuryOk,) = treasury.call{value: tip}("");
        if (!treasuryOk) revert TreasuryTransferFailed();
    }

    /// @notice Withdraw executor refunds parked by the pull-payment fallback.
    function pull() external nonReentrant {
        uint256 amount = pendingPull[msg.sender];
        if (amount == 0) revert NothingToPull();
        pendingPull[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit PullWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Admin (SPEC-7) - owner is the protocol Safe in production
    // ------------------------------------------------------------------

    function setTreasury(address payable _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasury();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setExecutor(address executor, bool authorized) external onlyOwner {
        if (executor == address(0)) revert InvalidTarget();
        authorizedExecutors[executor] = authorized;
        emit ExecutorSet(executor, authorized);
    }

    function setKeeperTip(uint128 _keeperTip) external onlyOwner {
        if (_keeperTip > MAX_KEEPER_TIP) revert TipOutOfBounds();
        keeperTip = _keeperTip;
        emit KeeperTipSet(_keeperTip);
    }

    function setMaxConsecutiveReverts(uint32 _maxConsecutiveReverts) external onlyOwner {
        if (_maxConsecutiveReverts == 0 || _maxConsecutiveReverts > MAX_REVERT_LIMIT) {
            revert RevertLimitOutOfBounds();
        }
        maxConsecutiveReverts = _maxConsecutiveReverts;
        emit MaxRevertsSet(_maxConsecutiveReverts);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Worst-case wei cost charged for one execution, used for both the
    ///      registration minimum and the pre-dispatch solvency check (RULE-3,
    ///      RULE-11). Bounded: measured gasUsed never exceeds
    ///      gasLimit + 2*OVERHEAD_BUFFER while OVERHEAD_BUFFER covers the
    ///      registry's own head checks and tail effects; the flat keeper tip
    ///      is added on top (DIV-D-3).
    function _worstCaseCost(uint32 gasLimit, uint256 gasPrice) internal view returns (uint256) {
        return (uint256(gasLimit) + 2 * uint256(OVERHEAD_BUFFER)) * gasPrice + keeperTip;
    }
}
