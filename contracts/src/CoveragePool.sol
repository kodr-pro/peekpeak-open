// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CoveragePool - AVAX-denominated L1 coverage terms (SPEC-13, Tier 2).
/// @notice Sponsors of sovereign Avalanche L1s (whose native gas token cannot
///         pay an AVAX-based operator) prepay keeper coverage HERE, on the
///         C-Chain, in AVAX. Coverage is a prepaid TIME TERM per chainId,
///         like an insurance premium: it gates the operator's service policy
///         (the worker stops poking an uncovered chain - fail-closed) and
///         never touches integrator escrows on the L1 itself.
/// @dev Security model:
///      - Funds are premium revenue, withdrawn by the treasury (Safe) on
///        receipt; the pool holds no refundable custody => no refund attack
///        surface and no custody obligation.
///      - `sponsor()` only ever EXTENDS a chain's expiry forward; it cannot
///        shorten an active term.
///      - `covered()` is the single source of truth the worker reads; expiry
///        is enforced by block.timestamp, not by off-chain promises.
///      - Owner (treasury Safe) sets the per-chain pricePerDay; price changes
///        only affect NEW deposits, never active terms.
contract CoveragePool is Ownable {
    uint256 public constant MAX_TERM_DAYS = 365;

    struct Term {
        uint64 expiresAt; // unix seconds; 0 = never sponsored
        uint128 totalFunded; // cumulative AVAX sponsored for this chain
    }

    /// @dev chainId => coverage term. chainId 0 is disallowed to prevent
    ///      confusing "all chains" semantics with an unset mapping slot.
    mapping(uint256 => Term) public terms;
    /// @dev chainId => AVAX per coverage day, set by the owner.
    mapping(uint256 => uint256) public pricePerDay;

    address payable public treasury;

    event Sponsored(uint256 indexed chainId, address indexed sponsor, uint256 amount, uint64 newExpiry);
    event PriceSet(uint256 indexed chainId, uint256 pricePerDay);
    event TreasurySet(address indexed treasury);
    event Withdrawn(address indexed to, uint256 amount);

    error UnpricedChain();
    error ZeroChainId();
    error TermTooLong();
    error InvalidTreasury();
    error InsufficientDeposit();
    error TransferFailed();

    constructor(address initialOwner, address payable initialTreasury) Ownable(initialOwner) {
        if (initialTreasury == address(0)) revert InvalidTreasury();
        treasury = initialTreasury;
    }

    /// @notice Prepay (or extend) keeper coverage for an L1 by whole days.
    /// @param chainId The L1's chain id (must be priced by the owner first).
    function sponsor(uint256 chainId) external payable {
        if (chainId == 0) revert ZeroChainId();
        uint256 price = pricePerDay[chainId];
        if (price == 0) revert UnpricedChain();
        if (msg.value < price) revert InsufficientDeposit();
        // RULE-6: totalFunded is uint128; bound the narrowing cast
        if (msg.value > type(uint128).max) revert InsufficientDeposit();

        uint256 days_ = msg.value / price; // whole days only
        if (days_ > MAX_TERM_DAYS) revert TermTooLong();
        uint64 base = terms[chainId].expiresAt;
        uint64 from = base > uint64(block.timestamp) ? base : uint64(block.timestamp);
        // extend forward only; cap at one year past the new base
        uint64 newExpiry = uint64(from + days_ * 1 days);
        terms[chainId] =
            Term({expiresAt: newExpiry, totalFunded: terms[chainId].totalFunded + uint128(msg.value)});

        (bool ok,) = treasury.call{value: msg.value}("");
        if (!ok) revert TransferFailed();

        emit Sponsored(chainId, msg.sender, msg.value, newExpiry);
    }

    /// @notice The worker's fail-closed gate: true while the term is active.
    function covered(uint256 chainId) public view returns (bool) {
        return terms[chainId].expiresAt > block.timestamp;
    }

    function coverage(uint256 chainId)
        external
        view
        returns (bool active, uint64 expiresAt, uint256 price)
    {
        return (covered(chainId), terms[chainId].expiresAt, pricePerDay[chainId]);
    }

    // ----- admin (owner = treasury Safe in production) -----

    function setPricePerDay(uint256 chainId, uint256 price) external onlyOwner {
        if (chainId == 0) revert ZeroChainId();
        pricePerDay[chainId] = price;
        emit PriceSet(chainId, price);
    }

    function setTreasury(address payable _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasury();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }
}
