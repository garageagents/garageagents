// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IMainBurner {
    function buyAndBurn() external payable returns (uint256 burned);
}

/// @title FeeSplitter
/// @notice The creator fee recipient of a pool whose hook is Programmable's EthereumNative30HookV3: the kernel's fee
///         vault pays the garage's share here (anyone can call the vault's claimCreator), and sync() books what
///         arrived. With an idea contract (an agent token): 80% is the idea's, 10% the agents' work wallet's and 10%
///         the treasury's; an idea share left unclaimed for a day can be spent by anyone on buying back and burning
///         the garage's main token. Without one (the main token): half to the agents, half to the treasury.
///         Anyone can pay out; each share only goes to its own address. The treasury can change the agents' and
///         the treasury's address, so the fees can move to a new wallet if a key ever has to be rotated; nothing here
///         can change the fee or the shares.
contract FeeSplitter {
    uint256 public constant IDEA_SHARE_BPS = 8_000; // with an idea contract: 80% of the garage's share
    uint256 public constant IDEA_GRACE = 1 days; // an idea share left unclaimed this long buys and burns the main token

    address public immutable idea; // 0: no idea contract (the main token)
    address public immutable mainBurner; // the main token's MainBurner: where an idle idea share goes
    address public agents; // the agents' work wallet: compute and gas
    address public treasury;

    uint256 public ideaAccrued;
    uint256 public ideaAccruedSince; // when the oldest unclaimed idea share arrived
    uint256 public agentsAccrued;
    uint256 public treasuryAccrued;
    uint256 public ideaTotal; // booked for the idea since launch
    uint256 public mainBurned; // main tokens bought back and burned with idle idea shares
    bool private _locked;

    event Booked(uint256 toIdea, uint256 toAgents, uint256 toTreasury);
    event Paid(address indexed to, uint256 amount);
    event IdeaShareBurnedMain(uint256 ethIn, uint256 mainTokensBurned);
    event AgentsSet(address agents);
    event TreasurySet(address treasury);

    error NotTreasury();
    error InvalidAddress();
    error NothingToPay();
    error TooEarly();
    error TransferFailed();
    error Reentrant();

    modifier locked() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address idea_, address mainBurner_, address agents_, address treasury_) {
        if (agents_ == address(0) || treasury_ == address(0) || (idea_ != address(0) && mainBurner_ == address(0))) {
            revert InvalidAddress();
        }
        idea = idea_;
        mainBurner = mainBurner_;
        agents = agents_;
        treasury = treasury_;
        emit AgentsSet(agents_);
        emit TreasurySet(treasury_);
    }

    receive() external payable {}

    /// @notice Books the ETH that arrived since the last call into the shares. Anyone can call, but not from inside a
    ///         payout: while one is under way the balance is mid-transfer and must not be booked again.
    function sync() external {
        if (_locked) revert Reentrant();
        _sync();
    }

    function _sync() private {
        uint256 owed = ideaAccrued + agentsAccrued + treasuryAccrued;
        if (address(this).balance <= owed) return;
        uint256 fresh = address(this).balance - owed;
        uint256 toIdea;
        if (idea != address(0)) {
            toIdea = fresh * IDEA_SHARE_BPS / 10_000;
            if (ideaAccrued == 0) ideaAccruedSince = block.timestamp;
            ideaAccrued += toIdea;
            ideaTotal += toIdea;
        }
        uint256 rest = fresh - toIdea;
        uint256 toAgents = rest / 2;
        agentsAccrued += toAgents;
        treasuryAccrued += rest - toAgents;
        emit Booked(toIdea, toAgents, rest - toAgents);
    }

    /// @notice Pays the agents' and the treasury's shares. Anyone can pay the gas.
    function payOut() external locked {
        _sync();
        uint256 toAgents = agentsAccrued;
        uint256 toTreasury = treasuryAccrued;
        if (toAgents + toTreasury == 0) revert NothingToPay();
        agentsAccrued = 0;
        treasuryAccrued = 0;
        _send(agents, toAgents);
        _send(treasury, toTreasury);
    }

    /// @notice Pays the idea contract its share. If its receive reverts, only this call reverts.
    function claimIdea() external locked returns (uint256 amount) {
        _sync();
        amount = ideaAccrued;
        if (amount == 0) revert NothingToPay();
        ideaAccrued = 0;
        _send(idea, amount);
    }

    /// @notice Use it or lose it: an idea share left unclaimed for IDEA_GRACE buys the main token at the market and
    ///         burns it. Anyone can call.
    function burnIdleIdeaShare() external locked returns (uint256 burned) {
        _sync();
        uint256 amount = ideaAccrued;
        if (amount == 0) revert NothingToPay();
        if (block.timestamp < ideaAccruedSince + IDEA_GRACE) revert TooEarly();
        ideaAccrued = 0;
        burned = IMainBurner(mainBurner).buyAndBurn{value: amount}();
        mainBurned += burned;
        emit IdeaShareBurnedMain(amount, burned);
    }

    function setAgents(address agents_) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (agents_ == address(0)) revert InvalidAddress();
        agents = agents_;
        emit AgentsSet(agents_);
    }

    function setTreasury(address treasury_) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Paid(to, amount);
    }
}
