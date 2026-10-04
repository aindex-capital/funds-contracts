// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  IFablesFeeDistributor
 * @notice Fables' weekly USDG pot (`PrologueFeeDistributor`, 0xc9ecc11728a4955b31f77c077b97fec521d78760): a
 *         cumulative Merkle distributor. Anyone may call `claim` for any account; the USDG always goes to that
 *         account. Leaves are `keccak256(bytes.concat(keccak256(abi.encode(account, cumulativeAmount))))`.
 */
interface IFablesFeeDistributor {
    function token() external view returns (address);
    function root() external view returns (bytes32);
    function claimed(address account) external view returns (uint256);
    function claim(address account, uint256 cumulativeAmount, bytes32[] calldata proof) external;
}
