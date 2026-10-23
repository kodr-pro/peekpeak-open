# PeekPeak

> **Peek the state. Poke the peak.**
> Contracts that run themselves - native automated execution for Avalanche C-Chain and L1s.

[peekpeak.app](https://peekpeak.app) · [Start](https://peekpeak.app/start) · [Docs](https://peekpeak.app/docs)

PeekPeak watches your contract's `checkJob()` on every block (free, off-chain),
verifies the execution would succeed, then calls `performJob()` on-chain through
an authorized executor. Escrow pays exactly the gas used plus a flat
**0.005 AVAX** tip. No token, no subscription, no markup. Reverting jobs cost
nothing. Your escrow is withdrawable at any time.

```solidity
interface IAutoJob {
    function checkJob() external view returns (bool canExec, bytes memory execPayload);
    function performJob(bytes calldata execPayload) external;
}
```

Two functions is the entire integration. The full walkthrough (with
paste-runnable commands against the live registry) is at
[peekpeak.app/start](https://peekpeak.app/start).

## This repository

The public face of the protocol:

- `contracts/` - `PeekRegistry`, `CoveragePool`, `IAutoJob`, the Pharaoh
  reference adapter, and the full Foundry test suite (MIT).
- `agents/SKILL.md` - the zero-config rulefile that lets AI agents (Cursor,
  Claude) implement the integration for you.

Protocol docs live at [peekpeak.app/docs](https://peekpeak.app/docs).
The production daemon and deployment configuration are private.

## Status

- **Live on Avalanche C-Chain** - registry
  [`0xb012fe01cd851c454bd5c7d20c3e3e3f98b4643d`](https://snowtrace.io/address/0xb012fe01cd851c454bd5c7d20c3e3e3f98b4643d),
  verified and executing jobs autonomously.
- **Security audit** commissioned; findings will be published.

## Support & feedback

[Open an issue](https://github.com/kodr-pro/peekpeak-open/issues) - bug
reports, integration questions, feature requests, and L1 onboarding
inquiries all welcome.

## License

MIT.
