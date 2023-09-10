// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import { PoolMock } from "./Mocks.sol";

contract ATokenMock {

    address underlying;

    string public name;
    string public symbol;

    uint8 public immutable decimals;

    uint256 private _totalSupply;

    PoolMock pool;

    mapping(address => uint256) private _balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address pool_
    ) {
        name       = name_;
        symbol     = symbol_;
        decimals   = decimals_;

        pool = PoolMock(pool_);
    }

    /**********************************************************************************************/
    /*** External Functions                                                                     ***/
    /**********************************************************************************************/

    function approve(address spender_, uint256 amount_) public virtual returns (bool success_) {
        _approve(msg.sender, spender_, amount_);
        return true;
    }

    function decreaseAllowance(address spender_, uint256 subtractedAmount_)
        public virtual returns (bool success_)
    {
        _decreaseAllowance(msg.sender, spender_, subtractedAmount_);
        return true;
    }

    function increaseAllowance(address spender_, uint256 addedAmount_)
        public virtual returns (bool success_)
    {
        _approve(msg.sender, spender_, allowance[msg.sender][spender_] + addedAmount_);
        return true;
    }
    function transfer(address recipient_, uint256 amount_) public virtual returns (bool success_) {
        _transfer(msg.sender, recipient_, amount_);
        return true;
    }

    function transferFrom(address owner_, address recipient_, uint256 amount_)
        public virtual returns (bool success_)
    {
        _decreaseAllowance(owner_, msg.sender, amount_);
        _transfer(owner_, recipient_, amount_);
        return true;
    }

    /**********************************************************************************************/
    /*** View Functions                                                                         ***/
    /**********************************************************************************************/

    function balanceOf(address user) public view returns (uint256) {
        return _balanceOf[user] * pool.getReserveNormalizedIncome(underlying) / 1e27;
    }

    function scaledBalanceOf(address user) public view returns (uint256) {
        return _balanceOf[user];
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply * pool.getReserveNormalizedIncome(underlying) / 1e27;
    }

    function scaledTotalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**********************************************************************************************/
    /*** Mock Functions                                                                         ***/
    /**********************************************************************************************/

    function mint(address account_, uint256 amount_) external virtual returns (bool success_) {
        _mint(account_, amount_);
        return true;
    }

    function burn(address account_, uint256 amount_) external virtual returns (bool success_) {
        _burn(account_, amount_);
        return true;
    }

    function setUnderlying(address underlying_) external {
        underlying = underlying_;
    }

    /**********************************************************************************************/
    /*** Internal Functions                                                                     ***/
    /**********************************************************************************************/

    function _approve(address owner_, address spender_, uint256 amount_) internal {
        allowance[owner_][spender_] = amount_;
    }

    function _burn(address owner_, uint256 amount_) internal {
        _balanceOf[owner_] -= amount_;

        // Cannot underflow because a user's balance will never be larger than the total supply.
        unchecked { _totalSupply -= amount_; }
    }

    function _decreaseAllowance(address owner_, address spender_, uint256 subtractedAmount_) internal {
        uint256 spenderAllowance = allowance[owner_][spender_];  // Cache to memory.

        if (spenderAllowance != type(uint256).max) {
            _approve(owner_, spender_, spenderAllowance - subtractedAmount_);
        }
    }

    function _mint(address recipient_, uint256 amount_) internal {
        _totalSupply += amount_;

        // Cannot overflow because totalSupply would first overflow in the statement above.
        unchecked { _balanceOf[recipient_] += amount_; }
    }

    function _transfer(address owner_, address recipient_, uint256 amount_) internal {
        _balanceOf[owner_] -= amount_;

        // Cannot overflow because minting prevents overflow of totalSupply,
        // and sum of user balances == totalSupply.
        unchecked { _balanceOf[recipient_] += amount_; }
    }

}
