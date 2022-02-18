// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PoolToken is ERC20, Ownable {
    address private _owner;
    constructor(uint256 _initialSupply) ERC20("POOL TOKEN","POOL") public{
        _owner = msg.sender;
        _mint(msg.sender, _initialSupply);
    }
}
