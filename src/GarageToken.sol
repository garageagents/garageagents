// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title GarageToken
/// @notice Fixed supply, no minting, no owner, no transfer taxes. The whole supply goes to the launcher,
///         which locks it in the pool forever. Fees are taken by the pool's hook, not by the token.
contract GarageToken is ERC20, ERC20Burnable {
    constructor(string memory name_, string memory symbol_, uint256 supply, address recipient) ERC20(name_, symbol_) {
        _mint(recipient, supply);
    }
}
